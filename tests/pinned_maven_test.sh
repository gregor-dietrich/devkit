#!/usr/bin/env bash
# Hermetic tests for scripts/lib/pinned_maven.sh: a temp copy of devkit's
# scripts/ whose pin is replaced by the sha256 of a fixture tarball, holding a
# fake mvn; stubs for curl (copies the fixture asset, or fails) and tar (logs,
# then runs the real one). No network. Prints PASS/FAIL per case.
set -euo pipefail

uncache() { chmod -R u+w "$@" 2>/dev/null || :; rm -rf "$@"; } # the caches are read-only, directories too
root=$(cd "$(dirname "$0")/.." && pwd)
# Physical, like secrets_test.sh: the script reports resolved paths. Two steps, so set -e catches a failed mktemp.
work=$(mktemp -d)
work=$(cd "$work" && pwd -P)
trap 'uncache "$work"' EXIT
export HOME=$work/home XDG_CACHE_HOME=$work/cache
unset DEVKIT_MAVEN_MIRROR # the mirror cases set it themselves
export LOG=$work/log # every stub appends a line here
mkdir -p "$HOME"
tools=$XDG_CACHE_HOME/devkit/tools
# shellcheck source=SCRIPTDIR/../scripts/lib/tree.sh
. "$root/scripts/lib/tree.sh"
# shellcheck source=SCRIPTDIR/../scripts/lib/sha256.sh
. "$root/scripts/lib/sha256.sh"
version=$(maven_version "$root")
pinned=$(sed -n 's/^sha256=//p' "$root/scripts/lib/pinned_maven.sh")
dir=$tools/maven-$version launcher=$dir/apache-maven-$version/bin/mvn
central=https://repo.maven.apache.org/maven2
path=org/apache/maven/apache-maven/$version/apache-maven-$version-bin.tar.gz

# The distribution stand-in: a fake mvn, and a stray file beside the top directory.
mkdir -p "$work/asset/apache-maven-$version/bin"
printf '#!/bin/sh\necho fake mvn\n' >"$work/asset/apache-maven-$version/bin/mvn"
chmod +x "$work/asset/apache-maven-$version/bin/mvn"
echo "not part of the distribution" >"$work/asset/stray"
tar -czf "$work/good.tar.gz" -C "$work/asset" "apache-maven-$version" stray
tar -czf "$work/bad.tar.gz" -C "$work/asset" stray

# The devkit under test: scripts/ with the pin moved to the fixture.
mkdir "$work/devkit"
cp -R "$root/scripts" "$work/devkit/"
script=$work/devkit/scripts/lib/pinned_maven.sh
sed "s/^sha256=.*/sha256=$(sha256_of "$work/good.tar.gz")/" "$root/scripts/lib/pinned_maven.sh" >"$script"
# The same, pinned to bad.tar.gz: its hash matches, but it lacks the distribution.
bad_script=$work/devkit/scripts/lib/pinned_maven_bad.sh
sed "s/^sha256=.*/sha256=$(sha256_of "$work/bad.tar.gz")/" "$root/scripts/lib/pinned_maven.sh" >"$bad_script"
chmod +x "$bad_script"

# Stubs, first on PATH; ${PATH#*:} drops their directory again.
mkdir "$work/bin"
stub() { # stub NAME BODY
  printf '#!/bin/sh\n%s\n' "$2" >"$work/bin/$1"
  chmod +x "$work/bin/$1"
}
# shellcheck disable=SC2016 # the bodies expand when the stubs run
{
  stub curl '[ "$1" != --help ] || { echo "${FAKE_CURL_HELP-}"; exit 0; }
echo "curl $*" >>"$LOG"
[ -z "${FAKE_CURL_FAIL-}" ] || exit 22
while [ $# -gt 0 ]; do [ "$1" = -o ] && cp "$FAKE_ASSET" "$2"; shift; done'
  stub tar 'echo "tar $*" >>"$LOG"; PATH=${PATH#*:}; exec tar "$@"'
}
export PATH=$work/bin:$PATH FAKE_ASSET=$work/good.tar.gz

run() { # run: the script; sets rc, out, err
  : >"$LOG"
  rc=0
  out=$("$script" 2>"$work/err") || rc=$?
  err=$(<"$work/err")
}
fails=0
t() { # t NAME COMMAND...: report whether COMMAND succeeds
  local name=$1
  shift
  if "$@"; then
    echo "PASS $name"
  else
    echo "FAIL $name (rc=$rc, stdout: $out, stderr: $err, log: $(<"$LOG"))"
    fails=$((fails + 1))
  fi
}
logged() { grep -q "^$1" "$LOG"; } # logged PREFIX: a log line starts with PREFIX
nothing_cached() { ! compgen -G "$tools/maven-*" >/dev/null && ! compgen -G "$tools/.tmp.*" >/dev/null; }
one_error() { # one_error TEXT: exactly one ERROR line, naming TEXT (the download line may precede it)
  local errors
  errors=$(grep '^ERROR' <<<"$err" || :)
  [[ $rc == 1 && $errors == "ERROR: pinned Maven: "*"$1"* && $errors != *$'\n'* ]]
}
curled() { # curled URL [RETRY]: the one download curl was asked for, retrying with RETRY
  grep -q "^curl -fsSL --proto =https --tlsv1.2 --connect-timeout 10 --max-time 300 --max-filesize 100M --retry 3 ${2:---retry-connrefused} --retry-max-time 300 -o $tools/.tmp.[^ ]*/asset.tar.gz $1$" "$LOG"
}

case_mismatch() {
  FAKE_ASSET=$work/bad.tar.gz run
  one_error "$central/$path" && [[ $err == *"devkit pins"* ]] && logged curl && ! logged tar && nothing_cached
}
case_no_download() {
  FAKE_CURL_FAIL=1 run
  one_error "cannot download $central/$path" && nothing_cached
}
case_install() {
  run
  [[ $rc == 0 && $out == "$launcher" && -x $launcher && -z $(find "$dir" ! -type l -perm -u+w) ]] &&
    curled "$central/$path" && [[ $(grep -c '^curl' "$LOG") == 1 ]] &&
    grep -q "^tar -xzf $tools/.tmp.[^ ]*/asset.tar.gz -C $tools/.tmp.[^ ]* apache-maven-$version$" "$LOG" &&
    [[ $(ls -A "$dir") == "apache-maven-$version" ]] && ! compgen -G "$tools/.tmp.*" >/dev/null || return 1
  run
  [[ $rc == 0 && $out == "$launcher" && -z $err ]] && ! logged curl && ! logged tar
}
case_retry_all_errors() { # a curl that knows --retry-all-errors (7.71 or later) retries every failure
  uncache "$dir"
  FAKE_CURL_HELP='     --retry-all-errors  Retry all errors (with --retry)' run
  [[ $rc == 0 && $out == "$launcher" ]] && curled "$central/$path" --retry-all-errors
}
case_bad_entry() { # an entry without a launcher is not downloaded over, link or not
  local ok=0
  uncache "$dir"
  mkdir -p "$dir"
  run
  one_error "$dir has no Maven launcher; remove it (chmod -R u+w '$dir'; rm -rf '$dir') and retry" && ! logged curl || ok=1
  rmdir "$dir"
  ln -s "$work/nowhere" "$dir"
  run
  one_error "$dir has no Maven launcher; remove it (chmod -R u+w '$dir'; rm -rf '$dir') and retry" &&
    ! logged curl && [[ -L $dir ]] || ok=1
  rm -f "$dir"
  return $ok
}
case_relative_cache() {
  XDG_CACHE_HOME=relative run
  one_error "tools cache relative/devkit/tools is not an absolute path" && ! logged curl
}
case_mirror() {
  uncache "$dir"
  DEVKIT_MAVEN_MIRROR=https://mirror.example/m2/ run
  [[ $rc == 0 && $out == "$launcher" ]] && curled "https://mirror.example/m2/$path"
}
case_mirror_http() {
  uncache "$dir"
  DEVKIT_MAVEN_MIRROR=http://mirror.example/m2 run
  one_error "must be an https:// base URL" && ! logged curl
}
case_mirror_credentials() { # refused without printing them, http or not, wherever the @ stands
  local value
  for value in https://user:s3cret@mirror.example/m2 http://s3cret@mirror.example/m2 https:///u:s3cret@h \
    https://u:s3cret/ss@h https:/u:s3cret@h //u:s3cret@h; do
    DEVKIT_MAVEN_MIRROR=$value run
    one_error "DEVKIT_MAVEN_MIRROR names a user or password" && [[ $out$err != *s3cret* ]] && ! logged curl || return 1
  done
}
case_mirror_malformed() { # refused before any download, without echoing the value: the second field is what must not leak
  local value leak pair
  for pair in "https://|DEVKIT_MAVEN_MIRROR=" "https://h |https://h" "https://h/p?token=x|token" "https://h#f|https://h#" \
    $'https://h/p\nx|h/p'; do
    value=${pair%%|*} leak=${pair#*|}
    DEVKIT_MAVEN_MIRROR=$value run
    one_error "must be an https:// base URL with a host and no query, fragment or whitespace" &&
      [[ $out$err != *"$leak"* ]] && ! logged curl || return 1
  done
}
case_mirror_warm_cache() { # a bad mirror is refused even when the launcher is cached
  uncache "$dir"
  run
  [[ $rc == 0 && -x $launcher ]] || return 1
  DEVKIT_MAVEN_MIRROR=http://mirror.example/m2 run
  one_error "must be an https:// base URL" && ! logged curl || return 1
  DEVKIT_MAVEN_MIRROR=https://s3cret@mirror.example run
  one_error "names a user or password" && [[ $out$err != *s3cret* ]] && ! logged curl
}
case_cannot_unpack() { # the hash matches the pin, but the distribution is not in the archive
  uncache "$dir"
  FAKE_ASSET=$work/bad.tar.gz script=$bad_script run
  one_error "cannot unpack $central/$path" && logged tar && nothing_cached
}
case_shipped_pin() {
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $pinned =~ ^[0-9a-f]{64}$ ]] &&
    [[ $(maven_pin "$root") == "$pinned  $path" ]]
}

t "1 a mismatched asset fails before tar, caching nothing" case_mismatch
t "2 a failed download fails, caching nothing" case_no_download
t "3 a matching asset installs only the distribution, read-only; the next run downloads nothing" case_install
t "3b a curl with --retry-all-errors retries every failure, an older one a refused connect" case_retry_all_errors
t "4 an entry without a launcher, or a dangling link, fails without a download" case_bad_entry
t "5 a relative cache root fails before any download" case_relative_cache
t "6 DEVKIT_MAVEN_MIRROR replaces Central, a trailing slash dropped" case_mirror
t "7 a mirror that is not https fails before any download" case_mirror_http
t "8 a mirror naming credentials, wherever the @ stands, fails without printing them" case_mirror_credentials
t "9 a mirror that is no https://HOST[/PATH] URL (credentials, query, fragment, whitespace) fails without a download or an echo" case_mirror_malformed
t "10 a bad mirror fails on a warm cache too" case_mirror_warm_cache
t "11 a matching archive without the distribution fails to unpack, caching nothing" case_cannot_unpack
t "12 the shipped pin is well-formed and maven_pin prints its checksums line" case_shipped_pin

[[ $fails == 0 ]] || {
  echo "$fails case(s) failed"
  exit 1
}
