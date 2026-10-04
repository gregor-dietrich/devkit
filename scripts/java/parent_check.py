#!/usr/bin/env python3
"""Check that the project inherits devkit's parent POM as docs/contract.md requires.

scripts/lib/get_maven.sh runs this before every Maven build: Maven reads the parent only
through the .devkit link, and anything that makes it look de.vptr.devkit:devkit-parent up
in a remote repository instead must fail here first. Every failure is one ERROR line on
stderr; exit 14.
"""

import os
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

from version_check import REPO_ROOT

DEVKIT: Path = Path(os.environ.get("DEVKIT", Path(__file__).resolve().parents[2]))
RELATIVE_PATH = ".devkit/java/parent/pom.xml"
UPGRADE_HINT = 'see "Upgrading from v0.1.x" in .devkit/README.md'
# Maven merges these lists with the parent's by position unless the consumer appends.
COMPILER_LISTS = ("compilerArgs", "annotationProcessorPaths")
EXIT_FAILED = 14


class Failure(Exception):
    """A check that failed; its message is the ERROR line."""


def text(element: ET.Element, path: str) -> str | None:
    """The trimmed text at a '/'-separated child path, in any or no XML namespace."""
    found = element.findtext("/".join(f"{{*}}{tag}" for tag in path.split("/")))
    return (found or "").strip() or None


def local_name(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def shown(path: Path) -> str:
    return str(path.relative_to(REPO_ROOT)) if path.is_relative_to(REPO_ROOT) else str(path)


def load(path: Path) -> ET.Element:
    try:
        return ET.parse(path).getroot()
    except (OSError, ET.ParseError) as exc:
        raise Failure(f"cannot read {shown(path)}: {exc}") from exc


def project_poms(root_pom: Path) -> list[tuple[Path, ET.Element]]:
    """The root pom and every pom its <modules> name, recursively, profiles included."""
    poms: list[tuple[Path, ET.Element]] = []
    pending, seen = [root_pom], {root_pom.resolve()}
    while pending:
        path = pending.pop(0)
        root = load(path)
        poms.append((path, root))
        for module in root.iterfind(".//{*}modules/{*}module"):
            target = path.parent / (module.text or "").strip()
            pom = target if target.is_file() else target / "pom.xml"
            if pom.is_file() and pom.resolve() not in seen:
                seen.add(pom.resolve())
                pending.append(pom)
    return poms


def pinned_version() -> str:
    """The [devkit] version devkit.toml pins, e.g. "v0.2.0"."""
    path = REPO_ROOT / "devkit.toml"
    try:
        with path.open("rb") as handle:
            version = tomllib.load(handle).get("devkit", {}).get("version")
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise Failure(f"cannot read {shown(path)}: {exc}") from exc
    if not isinstance(version, str) or not version:
        raise Failure(f"{shown(path)} has no [devkit] version.")
    return version


def check() -> str:
    """Raise Failure on the first broken rule; return the pass line."""
    devkit = load(DEVKIT / "java/parent/pom.xml")
    coordinate = f"{text(devkit, 'groupId')}:{text(devkit, 'artifactId')}"
    poms = project_poms(REPO_ROOT / "pom.xml")
    root = poms[0][1]

    parent = root.find("{*}parent")
    if parent is None or f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}" != coordinate:
        raise Failure(f"pom.xml does not inherit {coordinate}, which devkit requires since v0.2.0; {UPGRADE_HINT}.")
    relative_path = text(parent, "relativePath")
    if relative_path != RELATIVE_PATH:
        raise Failure(
            f"pom.xml's <parent><relativePath> must be {RELATIVE_PATH}, not {relative_path or 'empty or absent'}; "
            f"any other path makes Maven look {coordinate} up in remote repositories."
        )

    pin = pinned_version()
    expected = pin.removeprefix("v")
    if text(devkit, "version") != expected:
        raise Failure(
            f"devkit {pin}'s parent POM declares version {text(devkit, 'version')}: the pinned tag does "
            "not match its parent POM, which makes it a defective devkit release; pin another one."
        )
    found = text(parent, "version")
    if found != expected:
        raise Failure(
            f"pom.xml inherits {coordinate} {found}, but devkit.toml pins {pin}; "
            f"set <parent><version>{expected}</version>."
        )
    if text(root, "groupId") is None:
        raise Failure(
            "pom.xml has no <groupId> of its own: it would inherit devkit's, for its artifacts and for "
            "NullAway's annotated packages, which would then check none of the project's code."
        )

    owned = {local_name(p) for p in devkit.iterfind("{*}properties/*") if local_name(p).endswith(".version")}
    for path, pom in poms:
        for prop in pom.iterfind(".//{*}properties/*"):
            if local_name(prop) in owned:
                raise Failure(
                    f"partial migration: remove <{local_name(prop)}> from {shown(path)}; the parent owns it."
                )
        for plugin in pom.iterfind(".//{*}plugin"):
            if text(plugin, "artifactId") != "maven-compiler-plugin":
                continue
            for name in COMPILER_LISTS:
                for element in plugin.iterfind(f".//{{*}}{name}"):
                    if element.get("combine.children") != "append":
                        raise Failure(
                            f'{shown(path)} sets maven-compiler-plugin <{name}> without combine.children="append"; '
                            "Maven merges it with the parent's by position and drops the inherited "
                            "-Werror, Error Prone or NullAway."
                        )
    return f"devkit parent version check passed. ({found} == {pin})"


def main() -> None:
    try:
        print(check())
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(EXIT_FAILED)


if __name__ == "__main__":
    main()
