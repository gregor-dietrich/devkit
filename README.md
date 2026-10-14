# devkit

devkit is the build and quality-gate tooling that Maven and uv (Python)
projects would otherwise copy between each other: shared Make targets
(`make/`), the scripts behind them (`scripts/`), the shared Maven gate
configurations (`java/config/`) and a parent POM that applies them
(`java/parent/`).
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
text diff of `version` and `commit` in `devkit.toml`, plus the root pom's
`<parent><version>` in a Maven project (a release whose contract changes
lists its upgrade steps under [Releasing](#releasing)), and a cached
checkout works offline. The cache is
read-only: a change to shared tooling is made and released in devkit, never
edited inside a project. The wrapper fails closed: it never falls back to
another version and refuses a fetched commit that differs from the pin, is
not on devkit's `main`, or is named by a tag devkit's release key did not
sign.

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
   empty table when it has no minimums); a uv project, what its copy-paste
   gate scans in `[python.duplication] paths`, the duplicated file pairs it
   accepts, the anchored regex matches it accepts in
   `[[python.anchored-match.accepted]]` entries and the files that gate skips
   in `[[python.anchored-match.excluded]]` entries; and, optionally, the image
   namespaces it publishes itself in `[pins] first-party` and further YAML
   files `lint-pins` reads as workflows in `[pins] extra`;
3. adds `/.devkit` to `.gitignore` (a uv project also `/.venv`);
4. shapes its `Makefile` as the contract shows: profile variables,
   `DEVKIT := $(shell ./devkitw path)` and its empty-result guard,
   `include .devkit/make/common.mk` and one language file,
   `.devkit/make/java-maven.mk` or `.devkit/make/python-uv.mk`, then its
   own targets; a rule line ending in `## description` is listed by
   `make help`;
5. for Maven, inherits devkit's parent POM in its root pom, as
   [the contract](docs/contract.md#parent-pom) shows, with a `<groupId>` of
   its own, and keeps only its own values there: overrides of the parent's
   properties, exclusions and its own plugins. The parent runs every gate,
   with the project's `checkstyle-project.xml` as checkstyle execution
   `project`.

Then run `make hooks` once per clone: it installs the
[git hooks](docs/contract.md#git-hooks) that run `make lint-repo` before a
commit and `make lint-repo test` before a push. `make gate` runs that push
gate and records a clean, passing HEAD, so the next push skips it.

`make check` then fails when `.devkit` does not resolve to the pinned
checkout, warns when a git hook is missing or stale, and runs the language
checks (`make lint`, not `make check`, fails on a committed `devkitw` older
than the pin's); every target that runs Maven fails while the root pom does
not inherit the parent as the contract requires. `make lint` runs the
[repository gates](docs/contract.md#repository-gates) first, over the
whole repository, then the language gates. Requirements: git, GNU make,
ssh-keygen (OpenSSH 8.1 or later), bash as `/bin/bash`, and python3 (3.11 or
later); fetching a devkit release on a cache miss also needs the running UID to
have a passwd entry, which ssh-keygen requires (a container run with an
arbitrary `-u` UID needs one added); a uv project needs python3's venv and
pip only when no uv of the pinned version is on `PATH` or in devkit's
cache, and a `python3` on `PATH` (not `.venv`'s) that parses the project's
syntax, for the anchored-match gate. `make lint` also needs node (22.22.2
or later) with npm, for markdownlint and a uv project's copy-paste gate
(jscpd), and `make format` needs them for `format-md`, which fixes the
Markdown.
`make lint` also needs curl, tar and `sha256sum` or `shasum`, which fetch
and verify the pinned gitleaks once. So does the first target of a Maven
project on a machine, which fetches and verifies the pinned Maven the same
way (`DEVKIT_MAVEN_MIRROR`: [Parent POM](docs/contract.md#parent-pom));
every Java target runs that Maven, never `mvn` on `PATH`. Windows is not
targeted.

On a fresh clone, run any `make` target once: a bare `mvn`, an optional
`./mvnw` or an IDE's Maven import fails until the wrapper has created
`.devkit`.
"Non-resolvable parent POM … devkit-parent" means `.devkit` is missing or
points at another pin: run `make check`.

## Gating devkit itself

devkit is its own consumer: `make lint-repo`, `make hooks` and `make gate`
work here as in a project, and `make test` runs all of `tests/run.sh`, so
the push gate needs what its java and python parts need. By default
(`GATES=tree`) the targets run the working tree's own scripts, so each
change is gated by itself. With `GATES=release` they run the release
`devkit.toml` pins, fetched by `devkitw` as a consumer's is, so a change
that accidentally breaks a gate script does not pass on that gate alone;
`devkitw`, the `Makefile`, `devkit.toml` and the workflow stay the
change's own. CI runs `make lint-repo` both ways. `make gate` records
HEAD whichever way it ran, and `pre-push` then skips either.

`make check` applies to `GATES=release` only, since it requires `.devkit`
to resolve to the pin; run it once per clone, which also quiets the hooks'
notice that `.devkit` points at nothing. It compares the clone against the
pin, so while the tree has changed `devkitw` or the hooks since that release
it warns that they differ; that is expected here, and `make hooks` stays in
tree mode. `GATES=release` `lint-repo` fails when `./devkitw` differs from
the pinned release's copy without a higher `# devkitw revision` line, so a
change to `devkitw` raises the line once per release. Never copy the old
wrapper over devkit's own.

`make audit` runs `npm audit` over the lockfiles of the closures in
`markdown/` and `jscpd/`, so consumers need not audit them themselves: any
advisory fails it. It runs the working tree's scripts whichever `GATES` is
set, needs the network and fails closed without it; it asks
`registry.npmjs.org` whatever npm's own configuration says. Neither
`lint-repo`, `test` nor `gate` runs it. CI runs it on every pull request and
every push to `main`, as a required check, so a new advisory fails every
pull request until it is dealt with; the `audit` workflow also runs it
weekly. Every top-level directory holding a `package-lock.json` must be in
its list, which `tests/closure_audit_test.sh` checks. An advisory the
closure's gate never reaches goes in the closure's `audit-ignore`, one per
line: the GHSA id, the package npm reports it against, then why. An entry
without a package or a reason fails, and so does one that matches no
advisory, so a bump that fixes it forces its removal. Otherwise the fix is a
bump of the closure.

When a plugin's version, or parent configuration that changes what a plugin
resolves, changes in `java/parent/pom.xml`, run `make maven-checksums` and
commit `java/checksums/checksums.sha256` with the change; so does a bump of
the Maven `scripts/lib/pinned_maven.sh` pins. It records under that Maven,
so it needs JDK 25, curl, tar, `sha256sum` or `shasum` and a direct route to
Maven Central, but no Maven on `PATH`.
`tests/run.sh shell` fails on a pinned jar, or the pinned Maven
distribution's line, that the file lacks, but not on a changed transitive
closure, which only the re-record catches. The hashes are
trust on first use: whatever Central served over https when the target ran.
They detect a later substitution by a mirror, a proxy or the local
repository, not an artifact already malicious on Central; a re-record fails
when it would change the hash of a path already in the file (release paths
on Central are immutable), naming each path, and deleting that line and
re-running is the escape hatch.

## Releasing

A release is an annotated tag on `main`, signed with devkit's SSH release
key, whose allowed-signers line `devkitw` carries. `devkitw` refuses a tag
that key did not sign, one named other than the pinned version, and one whose
commit is not on `main`. The last check relies on every commit on `main` having
been reviewed, on devkit's remote and on the mirror a consumer may pin: `main`
protected, and pull requests squash-merged. The release commit sets the
version in `java/parent/pom.xml`, the `<parent>` versions of the fixtures in
`tests/fixtures/`, and in `docs/contract.md` the header, the TOML example's
`version` and the `<parent>` snippet's version; the tag is `v` + that
version, and `tests/run.sh` tags the tree under test under the same name.
A release whose `devkitw` changed since the previous release has raised its
`# devkitw revision` line.
Before tagging, review the parent's pins against Maven
Central (advisory, needs the network):

```sh
PROJECT_ROOT=java/parent python3 scripts/java/version_check.py
```

Run `make audit` as well; unlike that check, it must pass: a release ships
its closures to every consumer that bumps to it, so a failing advisory is
fixed or justified in the closure's `audit-ignore`, in a pull request of its
own, first.

Then tag, from `main`'s tip, with this snippet rather than `make tag`. It
needs git 2.34 or later and ssh-keygen (OpenSSH 8.1 or later), and
`user.signingKey` set to the release key in the clone's own config first:

```sh
git fetch -q origin main && git merge-base --is-ancestor HEAD FETCH_HEAD &&
tag=v$(python3 -c 'import sys, xml.etree.ElementTree as ET
version = ET.parse("java/parent/pom.xml").getroot().findtext("{http://maven.apache.org/POM/4.0.0}version")
print((version or "").strip() or sys.exit("java/parent/pom.xml declares no <version>"))') &&
  git -c gpg.format=ssh tag -a -s "$tag" -m "devkit $tag" &&
  git push origin "$tag"
```

The release key signs devkit's release tags and nothing else: a signature
binds the commit, type, tag name and namespace, not the repository.

Then, in a pull request of its own, point `devkit.toml` at the new release,
so that CI's `GATES=release` run gates the next changes with it: `version`
the tag, `commit` the peeled commit the tag names (as for a consumer's bump,
below):

```sh
commit=$(git ls-remote origin "refs/tags/${tag:?}^{}" | cut -f1) &&
  [ -n "$commit" ] && sed -i.bak -e "/^\[devkit\]/,/^\[/s/^version = .*/version = \"$tag\"/" \
    -e "/^\[devkit\]/,/^\[/s/^commit = .*/commit = \"$commit\"/" devkit.toml &&
  rm devkit.toml.bak && make lint-repo GATES=release
```

Tags are never moved to another commit, and never reused. Were one moved,
the wrapper would refuse the fetched commit rather than build with it.
v0.1.0 through v0.6.0 were re-signed once with the SSH release key, at their
same commits, so that the current wrapper fetches every release.

On devkit's forge, and on any mirror a consumer pins, only the maintainer may
create, move or delete `v*` tags. A signature does not stop anyone deleting a
pinned tag, and then every project without a cached copy fails closed.

A new release key ships in `devkitw` as a second allowed-signers line (the
single-quoted `signers` value may span lines; the rotation release loosens the
one-line guards in both `swap_signers` copies, in `tests/`), in a release the
old key signs. Every existing `v*` tag is re-signed with the new key at its
same commit, so a newer wrapper still fetches older releases, and later
releases are signed with the new key. A consumer bumps through the release
that carries both lines: a wrapper that knows only the old key, bumped
straight past it, refuses the tag as "not signed by devkit's release key".
The old line goes once every tag is re-signed and that release has shipped.

A consumer bumps by editing `version` and `commit` in `devkit.toml` and,
in a Maven project, the root pom's `<parent><version>` (the version without
the `v`), which is usually the whole diff; a release whose contract changes
lists its upgrade steps below. The commit is the one the tag points at,
which for an annotated tag is the peeled `^{}` entry:

```sh
git ls-remote <url> 'refs/tags/vX.Y.Z^{}'
```

If the release changed `devkitw`, the consumer also copies the new wrapper;
`make lint` fails until it does.

### Upgrading from v0.6.x

After the bump, copy the wrapper the old one has just fetched and verified,
and commit it with the bump: `cp .devkit/devkitw devkitw`. `make lint` fails
until the copy is committed (`lint-devkitw`), so a bump that edits only
`devkit.toml`, as Renovate's does, needs that one commit on its pull
request. The new wrapper refuses a tag devkit's release key did not sign or
that names another version. It needs ssh-keygen (OpenSSH 8.1 or later), which
macOS and most Linux installs carry; a CI image without it installs it
(`openssh-client` on Debian and Ubuntu) before the first make target. On a
cache miss ssh-keygen also needs the running UID to have a passwd entry: a
container run with an arbitrary `-u` UID fails with "ssh-keygen failed
verifying tag", naming ssh-keygen's own message.

Maven now verifies the plugins and annotation processors devkit's parent pins
against `.devkit/java/checksums/checksums.sha256` on every build the targets run
([Plugin checksums](docs/contract.md#plugin-checksums)). No action is needed. A
build that fails with a checksum error naming the summaryFile for a plugin or
dependency means the bytes Maven got, from a repository, a mirror or the local
repository, are not the ones devkit recorded: delete that artifact's directory
from the local repository and retry, and treat a repeat as a tampered mirror or
proxy. Artifacts the file does not list are not checked: a project's own
artifact, unless it shares a recorded coordinate; a gate plugin a project
switches to another version through a `-D<tool>.version` in `MAVEN_ARGS` or
`.mvn/maven.config` (the file records the pinned versions); a version
resolved through repository metadata (a range, `LATEST`, `RELEASE`). A
project that sets its own aether `trustedChecksums` (`record` included) or
`summaryFile` keys has them overridden for devkit's Maven calls (see the
first bullet of the contract's
[Plugin checksums](docs/contract.md#plugin-checksums)). The hashes are trust
on first use: they detect a later substitution, not an artifact already
malicious on Central. `MVN_CMD` now names devkit's checked wrapper; the
pinned launcher is in `MVN_LAUNCHER`, which matters to a project script
that sources `get_maven.sh` and inspects `MVN_CMD`.

Every Java target now runs the Maven 3.10.0 that devkit pins, never `mvn` on
`PATH` or `./mvnw`:

- The first target on a machine downloads it from Maven Central into
  devkit's tools cache, checks its sha256 and needs curl, tar, and `sha256sum`
  or `shasum`; later runs need no network for it. A network that reaches
  Central only through a mirror sets `DEVKIT_MAVEN_MIRROR` to the mirror's
  base URL: `https://`, a host and an optional path, with no `@`, `?`, `#` or
  whitespace anywhere, which every Java target refuses without printing it,
  since devkit prints the URL on a download and a path token would show.
  Authenticated mirrors and air-gapped seeding are unsupported (#134). The
  download uses curl, so a proxy comes from `https_proxy` or `HTTPS_PROXY`,
  not from Maven's `settings.xml`.
- A CI image drops a Maven install that served only devkit's targets, but only
  once the bump has landed: v0.6.x needs a Maven on `PATH`, so a rollback
  before then fails without it. A cache hit is not re-verified, so the tools
  directory is not restored from a shared CI cache; each fresh job downloads
  the roughly 9 MB once.
- Under make, the pinned Maven reads its own `conf/`, so a previously
  installed Maven's global `settings.xml` (mirrors, proxies, `<servers>`
  credentials) and its `lib/ext` no longer apply. Move them to
  `~/.m2/settings.xml`, or pass `-gs <file>` in `.mvn/maven.config`.
- An IDE or bare `mvn` lifecycle build now needs Maven 3.9.9 or later
  (`requireMavenVersion`): Maven 3.9.8 built Quarkus projects that passed the
  build and failed at runtime. `devkit.maven.range` can move that floor; a
  project that lowers it takes that risk back on itself.
- A project that does not pin maven-clean-plugin, maven-install-plugin or
  maven-jar-plugin itself now gets the versions the pinned Maven binds: 3.5.0,
  3.2.0 and 3.5.1.
- `./mvnw` stays optional, for an IDE or a bare build, and no target runs it.
  The refusal of a maven-wrapper jar (exit 15) is gone.
- `JAVA_VERSION` must be a plain JDK major number (`25`), and a trailing
  `# comment` on its line is fine; `make check` and `make install` exit 11
  otherwise, the other targets 1. A script of the project's own that calls
  `MVN_CMD` outside make exports it.
- The JDK check now runs in `make check` and in every lifecycle target
  (`install`, `lint`, `test`, `coverage`), through maven-enforcer-plugin, on
  the JDK Maven runs on: point `JAVA_HOME` at it, in CI too. `java` on `PATH`
  is no longer checked, and `make check` exits 11 when the enforcer fails.
  The check no longer obeys `enforcer.skip`, `enforcer.fail`,
  `enforcer.skipRules` or `enforcer.rules`, for a project that set them for
  its own executions.
- A pom that already declares maven-enforcer-plugin keeps its own
  executions; the parent's `environment` execution merges in by id. The
  parent also pins the plugin: a project removes any `enforcer-plugin.version`
  property of its own, which the parent check rejects, and any literal
  `<version>` on its declaration, so the parent's recorded 3.6.3 applies.

A remote that mirrors devkit must re-sync its `v*` tags with force (`git fetch
--force --tags` or equivalent), since v0.1.0 through v0.6.0 were re-signed as
new tag objects at the same commits; the new wrapper refuses a mirror still
serving the old unsigned objects.

In a Maven project ([Parent POM](docs/contract.md#parent-pom)), the shared PMD
ruleset no longer accepts the old helper list as assertions, REST Assured's
`statusCode` included: a test whose only check is `.then().statusCode(...)`
now fails UnitTestShouldIncludeAssert too. Such a project sets
`pmd.extraAssertMethodNames`, as a comma-separated list of method names, in
the `<properties>` of each pom that inherits devkit's parent: the root pom,
and any module that inherits it directly. It can copy the old value from
`java/config/pmd-ruleset.xml` at the v0.6.0 tag. Without it, every target that
runs PMD fails; the console says only "PMD … has found N violations", and the
rule and file are in `target/pmd.xml`. The parent now runs PMD on a filtered
copy of the ruleset, made at `initialize`, so a script of the project's own or
a CI step that runs `pmd:check` without a lifecycle phase runs `mvn initialize
pmd:check`. The parent also pins maven-resources-plugin: a project removes any
`resources-plugin.version` property of its own, which the parent check
rejects, and its own resource processing (default-resources and
default-testResources) moves from Maven's default 3.3.1 to 3.5.0.

The license check now allows only the licenses the parent lists in
`includedLicenses` ([Parent POM](docs/contract.md#parent-pom)): a dependency
under any other name fails the build, among them FSL-1.1-ALv2, vendor license
agreements and GPL with the Universal FOSS Exception, which only a FOSS project
appends. After the bump `make test` shows only "There are some forbidden
licenses used"; `mvn verify` without `-q` shows each license and its
dependencies. Add another spelling of an allowed license to `<includedLicenses
combine.children="append">` in `add-third-party`, one `<includedLicense>` per
name. Declare a dependency whose pom misstates its license in the module's
`src/license/override-THIRD-PARTY.properties`, under a name the parent lists or
the project appended.

The parent no longer sets `excludedLicenses`, so every name it does not list
fails, and a project's own `excludedLicenses` now applies at any level: one at
plugin level or as the `license.excludedLicenses` property, which the parent's
used to replace, takes effect again. While a project keeps one, plugin 2.7.1 can
fail with a `ConcurrentModificationException` on dependencies declaring an
allowed and an excluded name. Such a project, including one that set its own in
`add-third-party` as earlier upgrade notes suggested, deletes it and appends to
`includedLicenses` any name it let through, such as "Commercial" for an accepted
vendor dependency.

A project that set its own `includedLicenses` at plugin level or as the
`license.includedLicenses` property has it silently replaced by the parent's: it
moves the list into `add-third-party`, with `combine.children="append"` to
extend the parent's list. Without the attribute its list replaces the parent's,
so it also keeps "Unknown license" and every name its dependencies need. A
project that turned `failOnBlacklist` off has no allowlist check either: it
turns the option back on and exempts the dependency it was turned off for,
through `excludedGroups`, an override-file declaration, or by appending its
license.

In a uv project, `make lint` now fails on an anchored `.match()`, or a
`.search()` anchored at both ends, since `$` also matches before a trailing
newline ([uv projects](docs/contract.md#uv-projects)). Fix it with
`re.fullmatch` on an unanchored pattern or with `\A…\Z`; a line parser over
input that cannot carry a newline is accepted with a
`[[python.anchored-match.accepted]]` entry (`file`, `function`, `reason`).
A tracked `.py` that is not meant to parse (a fixture, a template) or
vendored code is excluded file by file with a
`[[python.anchored-match.excluded]]` entry (`file`, `reason`).
The gate checks the call shapes the contract lists and skips the rest, so a
project that keeps its own stricter check compares coverage before retiring
it. It parses with the system `python3`, not the project's interpreter, and
fails on a file it cannot parse: a project using syntax newer than its CI's
`python3` (`type X = …`, `def f[T]()` or `f"{d["k"]}"`, 3.12 and later, on
a 3.11 image) puts a newer `python3` on `PATH` there.

In a Maven project, `make check` now fails on a `FRONTEND_DIR` that is
neither one of `MODULES` nor `.` in a monolith, which only an empty `ONLY`
could select: set it to the frontend module's directory as `MODULES`
spells it, to `.` when a monolith's root is the frontend, or empty.

`make tag` now tags only the tip of origin's default branch, from a clean
tree, and only a tag shaped `X.Y.Z`, optionally prefixed `v` and followed by
`rcN` or `-rcN`. `REVISION` is checked the same way, so a
`REVISION=1.0.0-SNAPSHOT` left in the environment is refused rather than
tagged. Tags are ordered by git's version sort of the whole name, so a
`v`-prefixed tag ranks above any bare one: where both exist, type the next
tag instead of accepting the suggestion. A project that tags
release branches or uses another scheme tags by hand: `git tag -a -s <tag>`,
then `git push origin <tag>`.

Run `make hooks` to refresh the git hooks, so `pre-push` also warns on
`MAVEN_BASEDIR` and `MAVEN_DEBUG_OPTS` whenever they are set, and on a `-D`
option in `OPENJ9_JAVA_OPTIONS` or `IBM_JAVA_OPTIONS`, which the launcher of
devkit's Maven or its JVM reads; `make check` warns until then. `make gate`
no longer records under any of them; unsetting them restores the record.

### Upgrading from v0.5.x

After the bump, copy the wrapper the old one has just fetched and verified,
and commit it with the bump: `cp .devkit/devkitw devkitw`. The new wrapper
refuses a pinned commit that is not on devkit's `main`, and only a copied
wrapper does. `make lint` now fails until the copy is committed
(`lint-devkitw`), for this and every later release that changes `devkitw`,
so a bump that edits only `devkit.toml`, as Renovate's does, needs that one
commit on its pull request. `./devkitw self-check` is gone; `make check` no
longer warns about the wrapper. The new wrapper never asks an askpass
program (`GIT_ASKPASS`, `core.askPass`, `SSH_ASKPASS`), so a project whose
devkit fetch authenticated through one moves the credential into git
configuration, such as `http.<url>.extraHeader`, or into `~/.netrc`.

A module pom that inherits devkit's parent directly now gets the root pom's
checks: its `<relativePath>` must be the path from its directory to
`.devkit/java/parent/pom.xml` (`../.devkit/java/parent/pom.xml` for
`app-api/pom.xml`), its parent `<version>` the pin's, and it needs a
`<groupId>` of its own. A module that inherits the project's root pom is
unaffected.

devkit's caches (`~/.cache/devkit`, or `$XDG_CACHE_HOME/devkit`) are now
read-only directories as well as files, so a plain `rm -rf` of one fails:
a job or script that clears them runs `chmod -R u+w` on them first. An
entry cached before the bump keeps writable directories until removed.

A Maven project whose `./mvnw` launches a maven-wrapper jar
(any `distributionType` but `only-script`) regenerates it script-only, since
every target that runs Maven now fails on it: that launcher ignores
`MAVEN_ARGS`, so a profile such as `MAVEN_ARGS=-Pproduction` was silently
dropped wherever `./mvnw` ran instead of `mvn`. Run

```sh
./mvnw -N org.apache.maven.plugins:maven-wrapper-plugin:3.3.4:wrapper -Dtype=only-script
```

which keeps the wrapper's Maven version and removes `maven-wrapper.jar`
and `MavenWrapperDownloader.java`, then restore a `distributionSha256Sum`
line in `.mvn/wrapper/maven-wrapper.properties` if the old one had it, and
commit the result.

Recipes, and every `$(shell ...)` expanded after the includes, now run
under `/bin/bash` instead of `/bin/sh` (dash on Debian and Ubuntu), so the
project's own targets need `/bin/bash` too, as devkit's always did. A POSIX
recipe behaves the same unless it relies on dash's `echo` escapes (use
`printf`) or the environment sets `BASH_ENV`, which bash sources before
each recipe line and `$(shell ...)`. A `Makefile` that sets `SHELL` before
the includes moves the line directly after them, before any `$(shell ...)`,
to keep its own shell; `make SHELL=/bin/sh <target>` runs one target under
the old shell.

Run `make hooks` to refresh the git hooks, so `pre-push` ignores an `ONLY`
left in the shell, `pre-commit` and `pre-push` keep an outer make's flags (a
commit or push from inside a make recipe, or an exported `MAKEFILES` or
`GNUMAKEFLAGS`) from reaching their gates, and `pre-push` warns on variables
that can deselect tests (`MAVEN_ARGS`, `PYTEST_ADDOPTS`, a `-D` option in a
JVM options variable; a negated `-XX:-D…` flag no longer counts, for
`make gate` either); `make check` warns until then. `pre-push` also warns
on, and `make gate` no longer records under, a mavenrc file Maven runs
(`/usr/local/etc/mavenrc`, `/etc/mavenrc`, `~/.mavenrc`) or a
`~/.m2/settings.xml` with profile properties. Setting `MAVEN_SKIP_RC=1`
(for the mavenrc files) or moving those properties out of the settings file
restores the record.

A Maven project's installed and deployed poms are now flattened: no
`<parent>`, `${revision}` resolved, only the elements
[Parent POM](docs/contract.md#parent-pom) lists, so a downstream project,
and `ONLY` on a module that depends on a sibling, resolve them. A project
that configures flatten-maven-plugin itself first removes that
configuration, and any `flatten-plugin.version` property, which the parent
check now rejects: the configuration merges into devkit's, and Maven's
CI-friendly-versions setup then fails every build that reaches `verify`.
Then run `make install` once: poms installed before it still name devkit's
parent, and a downstream project needs the artifacts published again,
under a new version where the repository refuses to redeploy a release.

The license check no longer counts a module's own groupId as third party. A
project that set `excludedGroups` (in `add-third-party`, at plugin level or as
the `license.excludedGroups` property) sets it in `add-third-party` as
`^\Q${project.groupId}\E(?=:)|<its own groups>`, each written as
`^\Q<groupId>\E(?=:)` to match exactly that groupId: anywhere else devkit's
value replaces it. The license check also runs on every build now: a
dependency without license metadata, or under a blacklisted license, used to
fail only the first build after a clean and pass the next, and now fails every
one. Declare a missing license in the module's
`src/license/override-THIRD-PARTY.properties`
(`groupId--artifactId--version=License name`), not the
`THIRD-PARTY.properties` the error message names; exempt a blacklisted one
through `excludedGroups` as above, or override `failOnBlacklist` or
`excludedLicenses` in `add-third-party` ([Parent
POM](docs/contract.md#parent-pom)). Building again no longer helps.
A dependency under "Business Source License" or "Server Side Public License"
now fails the license check too: the parent's list wrapped inside those two
names, so they never matched.

### Upgrading from v0.4.x

v0.5.0 has `lint-md` read exactly one markdownlint configuration per file
and its `extends` chain (see
[Repository gates](docs/contract.md#repository-gates)). Besides the version
bump:

1. Move markdownlint settings kept anywhere else into the project's
   `.markdownlint.jsonc` or a `[markdown.profiles]` profile. v0.4.x merged
   beneath the configuration a `.markdownlintrc` in the project root or
   above it, `/etc/markdownlintrc`, `/etc/markdownlint/config` and, without
   a `.markdownlint.jsonc`, a root `.markdownlint.json`, `.yaml` or `.yml`;
   v0.5.0 ignores them. A file a configuration `extends` must be JSONC too.
2. Run `make hooks` to refresh the git hooks, so `pre-push` skips a HEAD
   that `make gate` verified; `make check` warns until then.

### Upgrading from v0.2.x

v0.3.0 adds the repository gates `lint-pins`, `lint-decisions`,
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
   wrap long lines by hand, exclude files in `.markdownlintignore`, add
   a `.markdownlint.jsonc` that extends devkit's profile, or give a subtree
   its own profile in `devkit.toml` (`[markdown.profiles]`).
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
