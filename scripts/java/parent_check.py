#!/usr/bin/env python3
"""Check that the project inherits one of devkit's parent POMs as docs/contract.md requires.

scripts/lib/get_maven.sh runs this before every Maven build: Maven reads the parent only
through the .devkit link, and anything that makes it look a de.vptr.devkit parent up in a
remote repository instead must fail here first. Every failure is one ERROR line on stderr;
exit 14. The root pom must inherit one of devkit's parent POMs; a module pom that inherits
one directly gets the root's relativePath, version and groupId rules. What else it refuses
is listed in docs/contract.md ("Parent POM").
"""

import os
import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NamedTuple, NoReturn

REPO_ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
DEVKIT: Path = Path(os.environ.get("DEVKIT", Path(__file__).resolve().parents[2]))
# devkit's parent POMs, each inheriting the one before it; paths inside the devkit checkout.
# Each release runs its own copy of this script, so the table only names that release's own files:
# a missing one is a defective release.
PARENTS = ("java/parent/pom.xml", "java/quarkus/pom.xml")
DEVKIT_GROUP = "de.vptr.devkit"
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


class Parent(NamedTuple):
    """One of devkit's parent POMs: its path in the checkout, its root element and groupId:artifactId."""

    path: str
    pom: ET.Element
    coordinate: str


def shipped_parents() -> list[Parent]:
    """The parents this devkit checkout ships, in inheritance order, coordinates read from their files."""
    shipped = []
    for entry in PARENTS:
        file = DEVKIT / entry
        if not file.is_file():
            raise Failure(f"devkit's {entry} is missing: a defective devkit release; pin another one.")
        pom = load(file)
        # A derived parent takes its version from its <parent> and needs its own groupId for the coordinate
        # below: an own <version> that differs from the pin makes Maven skip the local file and look the
        # parent up remotely. Checked here, before any coordinate is matched, so the defect is named.
        if shipped and (text(pom, "version") is not None or text(pom, "groupId") is None):
            defect = "declares no <groupId> of its own" if text(pom, "groupId") is None else "declares a <version> of its own"
            raise Failure(f"devkit {pinned_version()}'s {entry} {defect}: a defective devkit release; pin another one.")
        shipped.append(Parent(entry, pom, f"{text(pom, 'groupId')}:{text(pom, 'artifactId')}"))
    return shipped


def check_lists(path: Path, pom: ET.Element, sinks: str, advice: bool = True) -> None:
    """The append and sinks rules for one pom: what a merge with devkit's parent would drop.

    Each message is what is wrong, then, where there is one, the consumer's way out; advice=False leaves the way out off, for
    a parent devkit ships, where the only fix is another release.
    """

    def fail(wrong: str, way_out: str = "") -> NoReturn:
        raise Failure(wrong + way_out if advice else wrong.rstrip("."))

    for plugin in pom.iterfind(".//{*}plugin"):
        artifact = text(plugin, "artifactId")
        names, dropped = APPEND_LISTS.get(artifact, ((), ""))
        for name in names:
            for element in plugin.iterfind(f".//{{*}}{name}"):
                if element.get("combine.self") == "override":
                    fail(
                        f'{shown(path)} sets {artifact} <{name}> with combine.self="override"; '
                        "it drops the parent's list whatever combine.children says",
                        '; drop the override and use combine.children="append".',
                    )
                if element.get("combine.children") != "append":
                    fail(
                        f'{shown(path)} sets {artifact} <{name}> without combine.children="append"; '
                        f"Maven merges it with the parent's by position and {dropped}"
                    )
        if artifact != "spotbugs-maven-plugin":
            continue
        for element in plugin.iterfind(".//{*}configuration"):
            if element.get("combine.self") == "override":
                fail(
                    f'{shown(path)} sets spotbugs-maven-plugin <configuration> with combine.self="override"; '
                    "it drops the parent's whole configuration (find-sec-bugs, its JBoss Logging sinks, the "
                    "baseline)",
                    ", so drop the override.",
                )
        for element in plugin.iterfind(".//{*}systemPropertyVariables"):
            entry = element.find(f"{{*}}{SINKS_KEY}")
            if entry is None and element.get("combine.self") == "override":
                fail(
                    f'{shown(path)} sets spotbugs-maven-plugin <systemPropertyVariables> with combine.self="override" '
                    f"and without <{SINKS_KEY}>, which drops find-sec-bugs' JBoss Logging sinks",
                    f"; drop the override, or keep {sinks} in the ':'-joined value of <{SINKS_KEY}>.",
                )
            if entry is not None and sinks not in (entry.text or "").strip().split(":"):
                fail(
                    f"{shown(path)} sets spotbugs-maven-plugin <{SINKS_KEY}> without the parent's {sinks}; "
                    "it replaces the parent's value and drops find-sec-bugs' JBoss Logging sinks",
                    ", so keep that entry in the ':'-joined value.",
                )
        for element in plugin.iterfind(".//{*}jvmArgs"):
            if any(token.startswith(f"-D{SINKS_KEY}=") for token in (element.text or "").split()):
                fail(
                    f"{shown(path)} sets -D{SINKS_KEY} in spotbugs-maven-plugin <jvmArgs>, which the parent's "
                    "<systemPropertyVariables> entry defeats",
                    "; move a sink file into the "
                    f"value of <systemPropertyVariables><{SINKS_KEY}>, joined to the parent's with ':'.",
                )


def check() -> str:
    """Raise Failure on the first broken rule; return the pass line."""
    # SpotBugs splits its plugin list, and find-sec-bugs its sink files, on the path separator, so in
    # such a path find-sec-bugs would silently not load, while SpotBugs' own detectors still run.
    if os.pathsep in str(REPO_ROOT):
        raise Failure(
            f"the project path {REPO_ROOT} contains '{os.pathsep}', on which SpotBugs splits its plugin "
            "list: find-sec-bugs would silently not load; move the checkout to a path without it."
        )
    shipped = shipped_parents()
    base = shipped[0]
    poms = project_poms(REPO_ROOT / "pom.xml")

    def inherits(pom: ET.Element) -> tuple[ET.Element, Parent] | None:
        """The pom's <parent> and the devkit parent it names, if it names one."""
        parent = pom.find("{*}parent")
        found = None if parent is None else f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}"
        return None if parent is None else next(((parent, e) for e in shipped if e.coordinate == found), None)

    def check_parent(path: Path, pom: ET.Element, parent: ET.Element, entry: Parent) -> str:
        """The rules for a pom that inherits one of devkit's parents; return the pin."""
        # Physical: Maven opens <pom's dir>/<relativePath> as is, so .. leaves a symlinked directory.
        required = os.path.relpath(REPO_ROOT / ".devkit" / entry.path, path.parent.resolve())
        relative_path = text(parent, "relativePath")
        if relative_path != required:
            raise Failure(
                f"{shown(path)}'s <parent><relativePath> must be {required}, not {relative_path or 'empty or absent'}; "
                f"any other path makes Maven look {entry.coordinate} up in remote repositories."
            )
        pin = pinned_version()
        expected = pin.removeprefix("v")
        found = text(parent, "version")
        if found != expected:
            raise Failure(
                f"{shown(path)} inherits {entry.coordinate} {found}, but devkit.toml pins {pin}; "
                f"set <parent><version>{expected}</version>."
            )
        if text(pom, "groupId") is None:
            code = "the project's" if path.parent == REPO_ROOT else "its"
            raise Failure(
                f"{shown(path)} has no <groupId> of its own: it would inherit devkit's, for its artifacts and for "
                f"NullAway's annotated packages, which would then check none of {code} code."
            )
        return pin

    def check_release(pin: str) -> None:
        """Each shipped parent carries the pinned version and inherits the one before it."""
        expected = pin.removeprefix("v")
        if text(base.pom, "version") != expected:
            raise Failure(
                f"devkit {pin}'s parent POM declares version {text(base.pom, 'version')}: the pinned tag does "
                "not match its parent POM, which makes it a defective devkit release; pin another one."
            )
        for above, entry in zip(shipped, shipped[1:]):
            parent = entry.pom.find("{*}parent")
            wanted = os.path.relpath(DEVKIT / above.path, (DEVKIT / entry.path).parent)
            if parent is None or (
                f"{text(parent, 'groupId')}:{text(parent, 'artifactId')}",
                text(parent, "version"),
                text(parent, "relativePath"),
            ) != (above.coordinate, expected, wanted):
                raise Failure(
                    f"devkit {pin}'s {entry.path} does not inherit {above.coordinate} {expected} through "
                    f"{wanted}: a defective devkit release; pin another one."
                )

    for path, pom in poms:
        parent = pom.find("{*}parent")
        if parent is not None and text(parent, "groupId") == DEVKIT_GROUP and inherits(pom) is None:
            raise Failure(
                f"{shown(path)}'s <parent> names {DEVKIT_GROUP}:{text(parent, 'artifactId')}, which is none of "
                "devkit's parents; Maven would look it up remotely."
            )
    if (root_inherited := inherits(poms[0][1])) is None:
        names = [shipped[0].coordinate] + [e.coordinate.split(":")[1] for e in shipped[1:]]
        listed = f"{', '.join(names[:-1])} or {names[-1]}"
        raise Failure(
            f"pom.xml does not inherit a devkit parent ({listed}), which devkit requires since v0.2.0; {UPGRADE_HINT}."
        )
    root_parent = root_inherited[0]
    check_release(pinned_version())
    pin = check_parent(*poms[0], *root_inherited)
    deepest = shipped.index(root_inherited[1])
    for path, pom in poms[1:]:
        if (found := inherits(pom)) is not None:
            check_parent(path, pom, *found)
            deepest = max(deepest, shipped.index(found[1]))

    # The chains of the parents the project inherits are prefixes of the table: the union is the longest.
    owned = {
        local_name(p)
        for entry in shipped[: deepest + 1]
        for p in entry.pom.iterfind("{*}properties/*")
        if local_name(p).endswith(".version")
    }
    sinks = None
    for plugin in base.pom.iterfind(".//{*}plugin"):
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
        check_lists(path, pom, sinks)
    for entry in shipped[1:]:
        try:
            check_lists(DEVKIT / entry.path, entry.pom, sinks, advice=False)
        except Failure as exc:
            raise Failure(f"{exc}; devkit's own {entry.path}: a defective devkit release; pin another one.") from exc
    return f"devkit parent version check passed. ({text(root_parent, 'version')} == {pin})"


def main() -> None:
    try:
        print(check())
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(EXIT_FAILED)


if __name__ == "__main__":
    main()
