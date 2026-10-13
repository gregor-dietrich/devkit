#!/bin/bash

# devkit's own `make maven-checksums`, which no consumer target runs: regenerate
# java/checksums/checksums.sha256, the SHA-256 of every artifact the Maven plugin closure of
# devkit's parent POM resolves (scripts/lib/mvn_checked.sh verifies a build against it). Each
# java-* fixture of tests/fixtures is copied, .devkit linked to this tree, and put through the
# Maven goals of lint, test, coverage, install and format against a fresh, empty local
# repository (no read-through), with the resolver recording what it resolves; so is the
# dependency-check plugin's help goal, which resolves its closure without an NVD key, and so are
# the help and dependency plugins check_frontend_deps.py pins (read from it). The result replaces
# the file, sorted by path, and nothing else stays behind; one path recorded with two hashes
# fails the run, and so does a path the committed file lists with another hash (a release path on
# Central never changes: delete that line from the file to accept the new bytes, then re-run).
# Needs JDK 25, Maven >= 3.9.9, python3 3.11 or later, git and a direct route to Maven Central:
# no ~/.m2/settings.xml, mirror or proxy setting is read, since a build would record whatever
# bytes such a setting served, so a network that reaches Central only through a proxy cannot
# record.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=SCRIPTDIR/lib/python.sh
. "$root/scripts/lib/python.sh"
# shellcheck source=SCRIPTDIR/lib/tree.sh
. "$root/scripts/lib/tree.sh"
python3_floor
real=$(command -v mvn) || {
    echo "ERROR: mvn not found; recording needs Maven on PATH." >&2
    exit 1
}
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT
trap 'exit 1' HUP INT TERM

version=$(parent_version "$root")

# The plugins check_frontend_deps.py runs through MVN_CMD, as groupId:artifactId:version.
frontend=$(frontend_plugins "$root")
(($(wc -l <<<"$frontend") == 2)) || {
    echo "ERROR: check_frontend_deps.py does not pin exactly HELP_EVALUATE and DEPENDENCY_GET." >&2
    exit 1
}

# No user or system settings (profile repositories, proxy) steer what is recorded, and the global
# settings mirror every repository to Central over https, so that is the only place a transitive
# POM's <repository> can resolve from (an empty global settings would drop Maven's http blocker).
printf '%s\n' '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"/>' >"$tmp/settings.xml"
printf '%s\n' '<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0"><mirrors><mirror>' \
    '<id>central</id><mirrorOf>*</mirrorOf><url>https://repo.maven.apache.org/maven2</url>' \
    '</mirror></mirrors></settings>' >"$tmp/global-settings.xml"

# get_maven.sh picks this mvn, ahead of the real one, and every Maven call of the targets below goes
# through mvn_checked.sh (MVN_CMD), which puts its verify keys first; the keys after the build's own
# arguments win. So only what differs from them is set here: the file is recorded into
# $tmp/basedir, from a local repository that reads through to nothing.
mkdir "$tmp/bin" "$tmp/basedir"
printf '%s\n' '#!/bin/bash' \
    "[[ \$* == '-B -version' ]] && exec $(printf %q "$real") \"\$@\"" \
    "exec $(printf %q "$real") \"\$@\" \\" \
    "    -s $(printf %q "$tmp/settings.xml") -gs $(printf %q "$tmp/global-settings.xml") --strict-checksums \\" \
    "    -Dmaven.repo.local=$(printf %q "$tmp/repo") \\" \
    "    -Daether.trustedChecksumsSource.summaryFile.basedir=$(printf %q "$tmp/basedir") \\" \
    "    -Daether.artifactResolver.postProcessor.trustedChecksums.record=true" >"$tmp/bin/mvn"
chmod +x "$tmp/bin/mvn"

# The Maven goals of the java targets, without the repository gates (lint-repo, format-md). The
# fixture's Makefile exports the profile the scripts read; the help goals run through the same
# wrapper, MVN_LAUNCHER being the recording mvn.
cat >"$tmp/record.mk" <<'MK'
record:
	@set -e; for t in lint test coverage install format; do "$(DEVKIT)/scripts/java/$$t.sh"; done; \
		for p in org.owasp:dependency-check-maven $(FRONTEND); do \
			"$(DEVKIT)/scripts/lib/mvn_checked.sh" -B -q -N "$$p:help"; done
MK

# A clean environment, as tests/run.sh's prepare(): clean_env (scripts/lib/tree.sh) clears git's
# repository variables, devkit's own inputs, the Maven options and the JVM option variables
# (MAVEN_SKIP_RC leaves out ~/.mavenrc and /etc/mavenrc).
clean_env
export MAVEN_SKIP_RC=1 PATH=$tmp/bin:$PATH MVN_LAUNCHER=$tmp/bin/mvn

for fixture in "$root"/tests/fixtures/java-*/; do
    name=$(basename "$fixture")
    proj=$tmp/$name
    listed "$fixture" "$proj"
    ln -s "$root" "$proj/.devkit"
    printf '[devkit]\nversion = "v%s"\n' "$version" >"$proj/devkit.toml"
    echo "Recording $name..."
    env -u MAKEFLAGS -u MFLAGS -u GNUMAKEFLAGS -u MAKELEVEL -u MAKEFILES \
        make --no-print-directory -C "$proj" DEVKIT="$root" FRONTEND="${frontend//$'\n'/ }" -f Makefile -f "$tmp/record.mk" record
done

[[ -s $tmp/basedir/checksums.sha256 ]] || {
    echo "ERROR: nothing was recorded; the resolver's keys did not take effect." >&2
    exit 1
}
LC_ALL=C sort -u "$tmp/basedir/checksums.sha256" | LC_ALL=C sort -s -k2,2 >"$tmp/sorted"
conflicts=$(cut -d' ' -f3 "$tmp/sorted" | uniq -d)
[[ -z $conflicts ]] || {
    echo "ERROR: recorded with two different hashes: $conflicts" >&2
    exit 1
}
committed=$root/java/checksums/checksums.sha256
# A release path on Central never changes, so a new hash for a listed path is what a poisoned
# recording looks like; the committed file stays as it is.
changed=$([[ ! -f $committed ]] || awk 'FILENAME == ARGV[1] { hash[$2] = $1; next } ($2 in hash) && hash[$2] != $1 { print $2 }' \
    "$committed" "$tmp/sorted")
[[ -z $changed ]] || {
    while IFS= read -r path; do echo "ERROR: $path is recorded with another hash than the committed file lists." >&2; done <<<"$changed"
    echo "If Central really changed them, delete those lines from java/checksums/checksums.sha256, then re-run." >&2
    exit 1
}
mkdir -p "$root/java/checksums"
cat "$tmp/sorted" >"$root/java/checksums/checksums.sha256"
echo "Recorded $(wc -l <"$root/java/checksums/checksums.sha256") checksums in java/checksums/checksums.sha256."
