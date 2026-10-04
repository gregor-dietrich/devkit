# devkit

devkit is the build and quality-gate tooling that projects would otherwise
copy between each other: shared Make targets (`make/`), the scripts behind
them (`scripts/`), and the shared Maven gate configurations (`java/config/`).
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
`devkit.toml`. Nothing is installed globally, a bump is usually a two-line
text diff (a release whose contract changes lists its upgrade steps under
[Releasing](#releasing)), and a cached checkout works offline. The cache is
read-only: a change to shared tooling is made and released in devkit, never
edited inside a project. The wrapper fails closed: it never falls back to
another version and refuses a fetched commit that differs from the pin.

**Rejected options:**

- *Keep the Makefile and scripts in each project.* The two source projects
  drifted under a written by-hand sync policy; the same Quarkus/JaCoCo
  change had to land twice in one day.
- *git submodule.* Needs `git submodule update` after every checkout and
  rebase, recursive clones, and a dedicated submodule manager in dependency
  bots instead of a text edit. (The per-bump commit in the consumer is common
  to every pinned option and did not decide.)
- *A project template (Copier).* It allows local edits, which is the drift
  path, and turns scripts into templates tested only through rendered
  samples.
- *An installed CLI.* `uv tool` is Python tooling and an odd prerequisite for
  a Java build; a custom CLI is a product with a publish step per change.
- *A Claude Code plugin for everything.* Plugins update themselves per
  machine, but gates must be pinned per project for reproducible CI. A
  plugin carries agent tooling only.

## Adopting devkit

The interface is [docs/contract.md](docs/contract.md); every file here is
written against it. In short, a project:

1. copies `devkitw` from the release tag into its root, verbatim and
   executable, and never edits it;
2. adds `devkit.toml` with the pin (`url`, optional `mirror`, `version`,
   `commit`) and, when it has a frontend, its npm minimums in
   `[frontend.min-pins]`, which a project with a frontend requires (an
   empty table when it has no minimums);
3. adds `/.devkit` to `.gitignore`;
4. shapes its `Makefile` as the contract shows: profile variables,
   `DEVKIT := $(shell ./devkitw path)` and its empty-result guard,
   `include .devkit/make/common.mk` and `.devkit/make/java-maven.mk`, then
   its own targets; a rule line ending in `## description` is listed by
   `make help`;
5. points its pom at the shared configs through the link,
   `${maven.multiModuleProjectDirectory}/.devkit/java/config/<file>`, and
   runs its own `checkstyle-project.xml` as checkstyle execution `project`.

`make check` then fails when `.devkit` does not resolve to the pinned
checkout, warns when the committed `devkitw` is stale, and runs the language
checks. Requirements: git, GNU make, bash and python3 (3.11 or later);
Windows is not targeted. On a fresh clone, run any `make` target once: a
bare `./mvnw` fails until the wrapper has created `.devkit`.

## Releasing

A release is an annotated tag on `main`:

```sh
git tag -a vX.Y.Z -m "devkit vX.Y.Z"
git push origin vX.Y.Z
```

Tags are never moved or reused. Were one moved, the wrapper would refuse the
fetched commit rather than build with it.

A consumer bumps by editing `version` and `commit` in `devkit.toml`, which
is usually the whole diff; a release whose contract changes lists its
upgrade steps below. The commit is the one the tag points at, which for an
annotated tag is the peeled `^{}` entry:

```sh
git ls-remote <url> 'refs/tags/vX.Y.Z^{}'
```

If the release changed `devkitw`, the consumer also copies the new wrapper;
`make check` warns until it does.

### Upgrading from v0.1.x

v0.2.0 moves the values v0.1.x hardcoded for its first consumers into the
project. Following only the error messages can turn CI green with those
values silently dropped, so take every step:

1. Bump `version` and `commit` in `devkit.toml`.
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
4. Add the `project` execution to the pom's checkstyle plugin, as
   [the contract's snippet](docs/contract.md#maven-configuration) shows.
   Without it the project's rules never run, and nothing fails.
5. Make sure `python3` is 3.11 or later.

To roll back, restore the previous `version` and `commit`: the cached old
checkout is relinked offline, v0.1.x ignores the extra TOML table, and a
kept `project` execution just runs those rules a second time.
