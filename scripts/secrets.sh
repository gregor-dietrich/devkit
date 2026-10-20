#!/bin/bash
# Scan the project's git history and uncommitted changes for secrets with a
# pinned gitleaks (docs/contract.md, Repository gates). Three scans, all of
# which always run; the gate fails at the end if any failed:
#   - the changes of every commit reachable from HEAD, as `git log -p` shows
#     them (`--log-opts` below; gitleaks' own default, `git log --all`, would
#     make the verdict depend on whatever other refs the clone happens to
#     hold);
#   - the index (`--staged`);
#   - unstaged changes to tracked files (`--pre-commit`).
# The history scan's `--log-opts` are `HEAD`, `--text`, `--diff-merges=remerge`
# and `--no-textconv`. `--text` reads -diff and binary paths as text.
# `--diff-merges=remerge` reads a merge's own lines (what it changes against
# git's own re-merge: a conflict resolution, or a change a clean merge adds);
# it needs git 2.36 or later, and older git fails the scan through the ERR [git]
# check. git skips an octopus merge's lines with a warning on stdout.
# `--no-textconv` makes that scan ignore textconv drivers, which would rewrite
# what it reads. gitleaks itself may still skip content it detects as binary.
# Commit messages are in no scan, and a git that dies without writing to stderr
# (killed by a signal) is not detected. The staged and unstaged scans read
# changes as `git diff` shows them, so a path git treats as binary, or one a
# textconv driver rewrites, is read only once committed, by the history scan.
# Never `gitleaks dir`: it reads ignored files too, such as a local env file
# holding a real key, build output and installed dependencies.
#
# The binary is downloaded once per platform into the tools cache, and its
# release tarball is checked against the sha256 pinned below before anything
# unpacks it: a replaced asset would otherwise run over the whole checkout
# and decide the gate. Upstream signs nothing, not even its checksums file,
# so a release replaced before it was pinned here cannot be detected; the
# cross-checks below catch a corrupted or later-replaced download only.
#
# Bumping: set `version`; fetch that release's
# gitleaks_<version>_checksums.txt; cross-check each of the four platforms'
# hashes against the release API's per-asset `digest`
# (api.github.com/repos/gitleaks/gitleaks/releases/tags/v<version>) or the
# sha256 of the downloaded asset; update all four arms in one commit; re-check
# the ERR [git] log format scan() matches (tests/run.sh java provokes it), the
# merge-finding fingerprint forms (`b/` before a conflicted file's path, none
# elsewhere; tests/run.sh java pins both), the commit-less forms after a
# re-merge line holding `commit` (#189), and the path matching the contract
# advises (`^(b/)?`).
set -euo pipefail

# shellcheck source=SCRIPTDIR/lib/fetch.sh
. "$DEVKIT/scripts/lib/fetch.sh"

die() {
  echo "ERROR: lint-secrets: $*" >&2
  exit 1
}

cd "$PROJECT_ROOT"
[[ $(git rev-parse --is-inside-work-tree 2>/dev/null) == true ]] ||
  die "$PROJECT_ROOT is not a git work tree, or git refuses it (dubious ownership)"
# A shallow clone holds a fraction of the history, and gitleaks passes it.
[[ $(git rev-parse --is-shallow-repository) == false ]] ||
  die "shallow clone; lint-secrets scans the full history:" \
    "check out with full history (actions/checkout fetch-depth: 0)"

version=8.30.1
case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) platform=linux_x64 sha256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
  Linux/aarch64 | Linux/arm64) platform=linux_arm64 sha256=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
  Darwin/x86_64) platform=darwin_x64 sha256=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
  Darwin/arm64) platform=darwin_arm64 sha256=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
  *) die "devkit pins no gitleaks build for $(uname -s)/$(uname -m)" ;;
esac

tools=${XDG_CACHE_HOME:-$HOME/.cache}/devkit/tools
case $tools in /*) ;; *) die "tools cache $tools is not an absolute path" ;; esac
dir=$tools/gitleaks-$version-$platform gitleaks=$dir/gitleaks
if [[ ! -e $gitleaks ]]; then
  [[ ! -e $dir && ! -L $dir ]] || die "$dir has no gitleaks; remove it (chmod -R u+w '$dir'; rm -rf '$dir') and retry"
  url=https://github.com/gitleaks/gitleaks/releases/download/v$version/gitleaks_${version}_$platform.tar.gz
  echo "lint-secrets: downloading gitleaks $version ($platform)"
  fetch_sealed lint-secrets "$url" "$sha256" "$dir" gitleaks || exit 1
fi

# Only the project's own .gitleaks.toml and .gitleaksignore, which gitleaks
# reads from the scan root, may configure the gate.
unset GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
# Nor may the user's git configuration shape what gitleaks reads: with
# log.showRoot=false the root commit's diff is not shown, and colour codes
# from color.ui or color.diff hide every line from gitleaks' parser; either
# passes the scan. These override it, appended to any the caller set; git
# reads them since 2.31 (older git ignores them, which matters only before the
# first commit: the history scan fails on it anyway). The global configuration
# (safe.directory, for one) still applies.
n=${GIT_CONFIG_COUNT:-0}
for kv in log.showRoot=true color.ui=never color.diff=never diff.noprefix=false core.quotePath=true; do
  export "GIT_CONFIG_KEY_$n=${kv%%=*}" "GIT_CONFIG_VALUE_$n=${kv#*=}"
  n=$((n + 1))
done
export GIT_CONFIG_COUNT=$n
flags=(--redact --no-banner --verbose)
log=$(mktemp)
trap 'rm -f "$log"' EXIT
esc=$(printf '\033')

# scan MODE: one gitleaks scan, its output shown; it fails on gitleaks' exit
# status and on anything git wrote to stderr, which gitleaks logs at level ERR
# with the marker [git] (git's own text is localized) and then exits 0 on,
# having scanned part of the history or diff, or none of it.
scan() {
  local rc=0 plain
  "$gitleaks" git . "$1" "${flags[@]}" >"$log" 2>&1 || rc=$?
  cat "$log"
  plain=$(sed "s/$esc\[[0-9;]*m//g" "$log")
  if grep -qE '^([^ ]* )?ERR \[git\] ' <<<"$plain"; then
    echo "ERROR: lint-secrets: git failed under gitleaks git $1 (its ERR [git] lines above), so that scan is incomplete" >&2
    return 1
  fi
  return "$rc"
}

failed=false
# gitleaks passes a history scan on an unborn HEAD, where git log fails.
if git rev-parse -q --verify 'HEAD^{commit}' >/dev/null; then
  scan "--log-opts=HEAD --text --diff-merges=remerge --no-textconv" || failed=true
else
  echo "lint-secrets: no commit yet; skipping the history scan"
fi
scan --staged || failed=true
scan --pre-commit || failed=true
[[ $failed == false ]] ||
  die "gitleaks failed or found secrets (above). A secret: remove it and" \
    "rotate it; history keeps a committed one, so once rotated record its" \
    "Fingerprint in .gitleaksignore. A false positive: record its" \
    "Fingerprint in .gitleaksignore."
