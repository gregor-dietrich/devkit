#!/usr/bin/env python3
"""Check that the project inherits devkit's parent POM as docs/contract.md requires.

scripts/lib/get_maven.sh runs this before every Maven build: Maven reads the parent only
through the .devkit link, and anything that makes it look de.vptr.devkit:devkit-parent up
in a remote repository instead must fail here first. Every failure is one ERROR line on
stderr; exit 14. The root pom must inherit devkit's parent; a module pom that inherits it
directly gets the root's relativePath, version and groupId rules. What else it refuses is
listed in docs/contract.md ("Parent POM").
"""

import os
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
DEVKIT: Path = Path(os.environ.get("DEVKIT", Path(__file__).resolve().parents[2]))
RELATIVE_PATH = ".devkit/java/parent/pom.xml"
UPGRADE_HINT = 'see "Upgrading from v0.1.x" in .devkit/README.md'
# Maven merges these lists with the parent's by position unless the consumer appends; what a
# merge drops is the message's tail.
APPEND_LISTS = {
    "maven-compiler-plugin": (
        ("compilerArgs", "annotationProcessorPaths"),
        "drops the inherited -Werror, Error Prone or NullAway.",
    ),
    "spotbugs-maven-plugin": (("plugins",), "its plugin replaces find-sec-bugs."),
}
# The system property that hands find-sec-bugs the JBoss Logging sinks; the parent's value D for it
# must stay in a project's, joined to its own with ':' (find-sec-bugs splits it on File.pathSeparator).
SINKS_KEY = "findsecbugs.injection.customconfigfile.CrlfLogInjectionDetector"
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
    # SpotBugs splits its plugin list, and find-sec-bugs its sink files, on the path separator, so in
    # such a path find-sec-bugs would silently not load, while SpotBugs' own detectors still run.
    if os.pathsep in str(REPO_ROOT):
        raise Failure(
            f"the project path {REPO_ROOT} contains '{os.pathsep}', on which SpotBugs splits its plugin "
            "list: find-sec-bugs would silently not load; move the checkout to a path without it."
        )
    devkit = load(DEVKIT / "java/parent/pom.xml")
    coordinate = f"{text(devkit, 'groupId')}:{text(devkit, 'artifactId')}"
    poms = project_poms(REPO_ROOT / "pom.xml")

    def inherits(pom: ET.Element) -> ET.Element | None:
        parent = pom.find("{*}parent")
        found = None if parent is None else f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}"
        return parent if found == coordinate else None

    def check_parent(path: Path, pom: ET.Element, parent: ET.Element) -> str:
        """The rules for a pom that inherits devkit's parent; return the pin."""
        # Physical: Maven opens <pom's dir>/<relativePath> as is, so .. leaves a symlinked directory.
        required = os.path.relpath(REPO_ROOT / RELATIVE_PATH, path.parent.resolve())
        relative_path = text(parent, "relativePath")
        if relative_path != required:
            raise Failure(
                f"{shown(path)}'s <parent><relativePath> must be {required}, not {relative_path or 'empty or absent'}; "
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
                f"{shown(path)} inherits {coordinate} {found}, but devkit.toml pins {pin}; "
                f"set <parent><version>{expected}</version>."
            )
        if text(pom, "groupId") is None:
            code = "the project's" if path.parent == REPO_ROOT else "its"
            raise Failure(
                f"{shown(path)} has no <groupId> of its own: it would inherit devkit's, for its artifacts and for "
                f"NullAway's annotated packages, which would then check none of {code} code."
            )
        return pin

    root_parent = inherits(poms[0][1])
    if root_parent is None:
        raise Failure(f"pom.xml does not inherit {coordinate}, which devkit requires since v0.2.0; {UPGRADE_HINT}.")
    pin = check_parent(*poms[0], root_parent)
    for path, pom in poms[1:]:
        if (parent := inherits(pom)) is not None:
            check_parent(path, pom, parent)

    owned = {local_name(p) for p in devkit.iterfind("{*}properties/*") if local_name(p).endswith(".version")}
    sinks = None
    for plugin in devkit.iterfind(".//{*}plugin"):
        if text(plugin, "artifactId") == "spotbugs-maven-plugin":
            sinks = sinks or text(plugin, f"configuration/systemPropertyVariables/{SINKS_KEY}")
    if sinks is None:
        raise Failure(f"the parent POM has no spotbugs-maven-plugin <{SINKS_KEY}>: a defective devkit release.")
    for path, pom in poms:
        for prop in pom.iterfind(".//{*}properties/*"):
            if local_name(prop) in owned:
                raise Failure(
                    f"partial migration: remove <{local_name(prop)}> from {shown(path)}; the parent owns it."
                )
        for plugin in pom.iterfind(".//{*}plugin"):
            artifact = text(plugin, "artifactId")
            names, dropped = APPEND_LISTS.get(artifact, ((), ""))
            for name in names:
                for element in plugin.iterfind(f".//{{*}}{name}"):
                    if element.get("combine.self") == "override":
                        raise Failure(
                            f'{shown(path)} sets {artifact} <{name}> with combine.self="override"; '
                            f"it drops the parent's list whatever combine.children says, so drop the override and "
                            f'use combine.children="append".'
                        )
                    if element.get("combine.children") != "append":
                        raise Failure(
                            f'{shown(path)} sets {artifact} <{name}> without combine.children="append"; '
                            f"Maven merges it with the parent's by position and {dropped}"
                        )
            if artifact != "spotbugs-maven-plugin":
                continue
            for element in plugin.iterfind(".//{*}configuration"):
                if element.get("combine.self") == "override":
                    raise Failure(
                        f'{shown(path)} sets spotbugs-maven-plugin <configuration> with combine.self="override"; '
                        "it drops the parent's whole configuration (find-sec-bugs, its JBoss Logging sinks, the "
                        "baseline), so drop the override."
                    )
            for element in plugin.iterfind(".//{*}systemPropertyVariables"):
                entry = element.find(f"{{*}}{SINKS_KEY}")
                if entry is None and element.get("combine.self") == "override":
                    raise Failure(
                        f'{shown(path)} sets spotbugs-maven-plugin <systemPropertyVariables> with combine.self="override" '
                        f"and without <{SINKS_KEY}>, which drops find-sec-bugs' JBoss Logging sinks; drop the "
                        f"override, or keep {sinks} in the ':'-joined value of <{SINKS_KEY}>."
                    )
                if entry is not None and sinks not in (entry.text or "").strip().split(":"):
                    raise Failure(
                        f"{shown(path)} sets spotbugs-maven-plugin <{SINKS_KEY}> without the parent's {sinks}; "
                        "it replaces the parent's value and drops find-sec-bugs' JBoss Logging sinks, so keep "
                        "that entry in the ':'-joined value."
                    )
            for element in plugin.iterfind(".//{*}jvmArgs"):
                if any(token.startswith(f"-D{SINKS_KEY}=") for token in (element.text or "").split()):
                    raise Failure(
                        f"{shown(path)} sets -D{SINKS_KEY} in spotbugs-maven-plugin <jvmArgs>, which the parent's "
                        "<systemPropertyVariables> entry defeats; move a sink file into the "
                        f"value of <systemPropertyVariables><{SINKS_KEY}>, joined to the parent's with ':'."
                    )
    return f"devkit parent version check passed. ({text(root_parent, 'version')} == {pin})"


def main() -> None:
    try:
        print(check())
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(EXIT_FAILED)


if __name__ == "__main__":
    main()
