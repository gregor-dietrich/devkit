# devkit: working in this repository

devkit is the build and quality-gate tooling its consumers pin and link in
as `.devkit` through `devkitw` (README, "Why it looks like this"). A change
here reaches every consumer at its next bump, and decides whether their
builds pass: nothing consumer-specific lands here, and nothing that can
break a gate silently.

## Layout

| Path | What it is |
| ---- | ---------- |
| `docs/contract.md` | The consumer contract: what a consumer commits, `devkitw`, the Make targets, scripts, repository gates, git hooks, Maven and uv configuration. Every other file is written against it |
| `devkitw` | The wrapper a consumer copies verbatim: fetches the pinned commit once per machine, fails closed |
| `make/` | `common.mk` and the language files `java-maven.mk` and `python-uv.mk` a consumer's `Makefile` includes |
| `scripts/` | The scripts behind the targets: repository gates and git tooling at the top (and `closure_audit.*` and `maven_checksums.sh`, devkit's own `make audit` and `make maven-checksums`, which no consumer target runs), `java/`, `python/`, shared helpers in `lib/`, the git hook bodies in `hooks/` |
| `java/` | The shared Maven gate configurations (`config/`) and the parent POM that applies them (`parent/`), and the checksums of its plugin closure (`checksums/`) |
| `markdown/`, `jscpd/` | The pinned Node closures of markdownlint (with devkit's default profile) and jscpd |
| `tests/` | `run.sh`, the shell tests it runs, and the consumer fixtures in `fixtures/` |
| `Makefile`, `devkit.toml` | devkit gating itself, and the release pin `GATES=release` uses |

## Rules

- **Shared tooling changes are made and released here, never in a
  consumer.** A consumer's `.devkit` is a read-only cache and its
  `devkitw` a verbatim copy; a fix found there lands here, ships in a
  release, and reaches the consumer through a bump.
- `docs/contract.md` is the interface. A change to what a consumer
  commits, runs or may override updates the contract in the same change;
  one that makes a consumer act also adds upgrade steps to the README for
  the next release (`### Upgrading from vX.Y.x`).
- Name no consumer repository or person in shipped files; describe a
  consumer by its shape (a Maven monolith, a uv workspace).
- A pin bump takes only a release published at least 24 hours before the
  bump's commit (README, "Gating devkit itself").
- Shell scripts pass shellcheck; Python helpers run on python3 3.11 or
  later (`scripts/lib/python.sh` checks the floor before any helper).
- Markdown is hard-wrapped at 80 columns (`markdown/markdownlint.jsonc`).
- Security-relevant paths, which take a full `/agent-kit:ai-review`
  rather than one reviewer: `devkitw` and the gate that delivers it
  (`scripts/devkitw.sh`); what fetches, verifies and seals a tool
  (`scripts/lib/get_uv.sh`, `scripts/lib/node_closure.sh`,
  `scripts/lib/fetch.sh`, `scripts/lib/pinned_maven.sh`, which pins the
  Maven every Java target runs, `scripts/lib/sha256.sh`,
  `scripts/lib/sealed_dir.sh`,
  `scripts/secrets.sh`, `scripts/python/uv_project.py`, which writes the
  uv bootstrap's hashes, and the lockfiles in `markdown/` and `jscpd/`);
  what decides whether an advisory against them is silenced
  (`scripts/closure_audit.sh`, `scripts/closure_audit.py` and each
  closure's `audit-ignore`); what pins the Maven plugin closure
  (`java/checksums/`, `scripts/maven_checksums.sh`,
  `scripts/lib/get_maven.sh`, `scripts/lib/mvn_checked.sh` and
  `scripts/java/check_frontend_deps.py`, whose constants name plugins the
  file must hold);
  the git hooks and the record that lets `pre-push` skip
  (`scripts/hooks/`, `scripts/hooks.sh`, `scripts/gate.sh`); and
  `.gitea/workflows/`.

## Gates

- `make lint-repo` runs devkit's repository gates over its own tree: pins,
  decisions, gitleaks and markdownlint. `GATES=tree` (the default) runs the
  working tree's scripts, `GATES=release` those of the release
  `devkit.toml` pins; CI runs both (README, "Gating devkit itself").
- `make test` runs all of `tests/run.sh`. `tests/run.sh shell`, `java` or
  `python` runs one part; its header lists what each part needs. The
  shell part needs the npm registry on first use; the java and python
  parts build every fixture in a fresh cache and need the network on every
  run.
- `make audit` runs `npm audit` over the `markdown/` and `jscpd/`
  lockfiles; it needs the network, and neither `lint-repo`, `test` nor
  `gate` runs it. CI's `audit` job runs it on every pull request and every
  push to `main`, `.gitea/workflows/audit.yml` weekly, and a release is
  tagged only after it passes. A new closure joins its list in the
  `Makefile`.
- `make maven-checksums` regenerates `java/checksums/checksums.sha256`
  after a plugin version in the parent, or the Maven version
  `pinned_maven.sh` pins, changes (network; `tests/run.sh
  shell` fails without it).
- `make hooks` once per clone; `make gate` runs `make lint-repo test` and
  records a passing clean HEAD, so `pre-push` skips it. Commit first, then
  run `make gate`, then push.
- `make check` applies to `GATES=release` only. `GATES=release`
  `lint-repo` fails when `./devkitw` differs from the pinned release's copy
  without a higher `# devkitw revision`: a change to `devkitw` raises that
  line once per release. Never copy the old wrapper over devkit's own.

## Releasing

The procedure is the README's "Releasing" section, step by step: follow
it rather than `make tag`. Tags are never moved to another commit or reused.

## Agent tooling

`.claude/settings.json` enables the agent-kit plugin for Claude Code;
install it per machine as its README describes. Its marketplace entry
declares `"autoUpdate": true` so no machine needs the `/plugin`
auto-update toggle, which writes into the first settings file declaring
the marketplace and would dirty this one: to change it on one machine,
declare the marketplace in the gitignored `.claude/settings.local.json`
instead.

Generic method is agent-kit's and is not restated here: its skills
`delegation` (dispatching subagents), `review-triage` and `ai-review`
(reviews), `debugging`, `design-exploration`, and `plan-create` /
`plan-run` (planning and executing a change). This file holds only what
is specific to devkit.

<!-- agent-kit:codex-bridge -->
