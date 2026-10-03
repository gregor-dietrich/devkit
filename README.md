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
`devkit.toml`. Nothing is installed globally, nothing shared can be edited
locally, a bump is a two-line text diff, and a cached checkout works
offline. The wrapper fails closed: it never falls back to another version
and refuses a fetched commit that differs from the pin.

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
   `commit`);
3. adds `/.devkit` to `.gitignore`;
4. shapes its `Makefile` as the contract shows: profile variables,
   `DEVKIT := $(shell ./devkitw path)`, the includes, then its own targets;
   a rule line ending in `## description` is listed by `make help`;
5. points its pom at the shared configs through the link,
   `${maven.multiModuleProjectDirectory}/.devkit/java/config/<file>`.

`make check` then verifies, besides the language checks, the wrapper against
the pin and the `.devkit` link against the checkout. Requirements: git, GNU
make, bash and python3; Windows is not targeted. On a fresh clone, run any
`make` target once: a bare `./mvnw` fails until the wrapper has created
`.devkit`.

## Releasing

A release is an annotated tag on `main`:

```sh
git tag -a vX.Y.Z -m "devkit vX.Y.Z"
git push origin vX.Y.Z
```

Tags are never moved or reused. Were one moved, the wrapper would refuse the
fetched commit rather than build with it.

A consumer bumps by editing `version` and `commit` in `devkit.toml`. The
commit is the one the tag points at, which for an annotated tag is the
peeled `^{}` entry:

```sh
git ls-remote <url> 'refs/tags/vX.Y.Z^{}'
```

If the release changed `devkitw`, the consumer also copies the new wrapper;
`make check` reports the mismatch until it does.
