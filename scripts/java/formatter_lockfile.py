#!/usr/bin/env python3
"""Check that the trusted checksums cover the Eclipse formatter Spotless runs.

Spotless provisions the formatter through Maven, so under the trusted checksums, only when
the spotless-lib-extra it runs embeds a lockfile for the formatter version; without one it
fetches the formatter from P2, outside Maven and so unchecked.

Usage:  formatter_lockfile.py POM REPO CHECKSUMS
  POM       the parent POM: its eclipse-formatter.version property, which the
            spotless-maven-plugin's <eclipse><version> must be exactly
  REPO      a local Maven repository root, holding the spotless-lib-extra jar
  CHECKSUMS a trusted checksums file (java/checksums/checksums.sha256's format: the hash, two
            spaces, the repository-relative path), which lists that one jar
Fails, one ERROR line per problem on stderr and exit 1, unless the jar embeds the lockfile
of the version and the file lists the jar of every coordinate the lockfile names. Silent on
success.
"""

import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

NS = "{http://maven.apache.org/POM/4.0.0}"
PROPERTY = "eclipse-formatter.version"
LIB_JAR = re.compile(
    r"com/diffplug/spotless/spotless-lib-extra/([^/\s]+)/spotless-lib-extra-\1\.jar"
)


def check(pom: Path, repo: Path, checksums: Path) -> list[str]:
    errors: list[str] = []
    root = ET.parse(pom).getroot()
    version = (root.findtext(f"{NS}properties/{NS}{PROPERTY}") or "").strip()
    if not version:
        return [f"{pom} sets no {PROPERTY} property"]
    used = [
        (plugin.findtext(f"{NS}configuration/{NS}java/{NS}eclipse/{NS}version") or "").strip()
        for plugin in root.iter(f"{NS}plugin")
        if plugin.findtext(f"{NS}artifactId") == "spotless-maven-plugin"
        and plugin.find(f"{NS}configuration/{NS}java/{NS}eclipse") is not None
    ]
    if used != ["${" + PROPERTY + "}"]:
        errors.append(
            f"the spotless-maven-plugin's <eclipse><version> in {pom} is {used}, not exactly "
            f"${{{PROPERTY}}}, so this check does not cover the formatter Spotless runs"
        )
    listed: set[str] = set()
    for line in checksums.read_text(encoding="utf-8").splitlines():
        parts = line.split("  ", 1)
        if len(parts) == 2:
            listed.add(parts[1].strip())
    libs = sorted(path for path in listed if LIB_JAR.fullmatch(path))
    if len(libs) != 1:
        errors.append(f"{checksums} lists {len(libs)} spotless-lib-extra jars, expected exactly one")
        return errors
    jar_path = repo / libs[0]
    if not jar_path.is_file():
        errors.append(f"{jar_path} does not exist; build a java project so Maven resolves it")
        return errors
    entry = f"com/diffplug/spotless/extra/eclipse_jdt_formatter/v{version}.lockfile"
    with zipfile.ZipFile(jar_path) as jar:
        if entry not in jar.namelist():
            errors.append(
                f"{jar_path.name} embeds no lockfile for {PROPERTY} {version}, so Spotless would "
                "provision the formatter from P2, outside the trusted checksums; pick a version "
                "it has a lockfile for, or wait for a Spotless release that embeds one"
            )
            return errors
        lockfile = jar.read(entry).decode("utf-8")
    for line in lockfile.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        coordinate = line.split(":")
        if len(coordinate) != 3 or not all(coordinate):
            errors.append(f"{entry} holds a line that is not group:artifact:version: {line!r}")
            continue
        group, artifact, ver = coordinate
        path = f"{group.replace('.', '/')}/{artifact}/{ver}/{artifact}-{ver}.jar"
        if path not in listed:
            errors.append(
                f"{checksums} does not list {path}: make maven-checksums has not recorded "
                f"{PROPERTY} {version}"
            )
    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    errors = check(Path(argv[0]), Path(argv[1]), Path(argv[2]))
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
