#!/usr/bin/env python3
"""Report pom.xml version properties whose artifacts have a newer release on Maven Central or
DEVKIT_MAVEN_MIRROR.

A version property is the unit of work: it is what you edit to bump, and one property can
pin several artifacts (${vaadin.version} covers three). The artifacts behind each property
are resolved from the pom so the repository can be queried by real groupId:artifactId.

Multi-module projects are scanned as the root pom plus every <modules> pom; module poms
inherit the root pom's properties, and dependencies between the project's own modules are
skipped (they are not published).
"""

import http.client
import os
import re
import signal
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import xml.parsers.expat
from pathlib import Path
from typing import NamedTuple

# Repo root is the consuming project: $PROJECT_ROOT, which devkit's make includes
# export to every recipe, else the current working directory.
REPO_ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
POM_PATH: Path = REPO_ROOT / "pom.xml"

POM_NS = {"m": "http://maven.apache.org/POM/4.0.0"}

# Elements that declare a Maven coordinate: plain dependencies (incl. dependencyManagement),
# build plugins (incl. the ones inside profiles), annotationProcessorPaths entries and
# build extensions.
COORDINATE_TAGS = ("dependency", "plugin", "path", "extension")

# <plugin> may omit <groupId>; Maven then assumes its own plugin group.
DEFAULT_PLUGIN_GROUP = "org.apache.maven.plugins"

MAVEN_CENTRAL = "https://repo1.maven.org/maven2"
# The rule every Java target holds DEVKIT_MAVEN_MIRROR to (docs/contract.md, Parent POM):
# https://HOST[/PATH], no @ anywhere, no query, fragment or whitespace.
MIRROR_URL = re.compile(r"https://[^/@?#\s]+(/[^?#\s]*)?")
REQUEST_TIMEOUT = 15  # per socket operation
# Seconds of wall clock for one whole metadata lookup (connect, TLS, headers, redirects, body), a
# trickling server included; a DNS lookup that ignores signals is bounded only by the resolver.
LOOKUP_DEADLINE = 60
MAX_METADATA_BYTES = 1024 * 1024  # 1 MiB: maven-metadata.xml is kilobytes (the largest on Central is about 65 KB)

# A <release>/<latest> marker is printed, notes included, so it must look like a version: no space,
# comma or colon to forge another artifact's entry with, no control character, at most 100 characters.
MARKER = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_-]{0,99}")

PLACEHOLDER = re.compile(r"\$\{([^}]+)\}")

# Guard against a property cycle (${a} -> ${b} -> ${a}) while resolving placeholders.
MAX_RESOLVE_DEPTH = 10


class Coordinate(NamedTuple):
    """A Maven groupId:artifactId."""

    group: str
    artifact: str

    def __str__(self) -> str:
        return f"{self.group}:{self.artifact}"


class Pin(NamedTuple):
    """One edit site in the pom: a version property and every artifact it pins."""

    name: str  # property name, or "group:artifact" when a version is hardcoded
    version: str
    coordinates: list[Coordinate]
    is_property: bool


class PomScan(NamedTuple):
    """Everything the pom parse yields."""

    pins: list[Pin]
    artifact_count: int
    notes: list[str]  # human-readable reasons for declarations that were skipped
    unmapped_properties: list[str]  # *.version properties no artifact resolves to


def get_properties(root: ET.Element) -> dict[str, str]:
    """Collect every <properties> entry in the pom (project level plus profiles)."""
    properties: dict[str, str] = {}
    for block in root.iterfind(".//m:properties", POM_NS):
        for entry in block:
            name = entry.tag.split("}")[-1]
            properties.setdefault(name, (entry.text or "").strip())
    return properties


def resolve(value: str, properties: dict[str, str], depth: int = 0) -> str | None:
    """Expand ${...} placeholders from the pom properties; None if any cannot be resolved."""
    if "${" not in value:
        return value
    if depth >= MAX_RESOLVE_DEPTH:
        return None
    resolved = value
    for name in PLACEHOLDER.findall(value):
        replacement = properties.get(name)
        if replacement is None:
            return None
        expanded = resolve(replacement, properties, depth + 1)
        if expanded is None:
            return None
        resolved = resolved.replace(f"${{{name}}}", expanded)
    return resolved


def child_text(element: ET.Element, name: str) -> str | None:
    """Return the trimmed text of a direct child element, or None if absent/empty."""
    child = element.find(f"m:{name}", POM_NS)
    if child is None or child.text is None:
        return None
    text = child.text.strip()
    return text or None


def project_coordinate(root: ET.Element) -> Coordinate | None:
    """The pom's own groupId:artifactId, with the groupId inherited from <parent> if absent."""
    artifact = child_text(root, "artifactId")
    group = child_text(root, "groupId")
    if group is None:
        parent = root.find("m:parent", POM_NS)
        if parent is not None:
            group = child_text(parent, "groupId")
    return Coordinate(group, artifact) if group and artifact else None


def find_pom_paths(root_pom: Path) -> list[Path]:
    """The root pom followed by the pom of every <modules> entry it declares."""
    poms = [root_pom]
    root = ET.parse(root_pom).getroot()
    for module in root.iterfind(".//m:modules/m:module", POM_NS):
        module_pom = root_pom.parent / (module.text or "").strip() / "pom.xml"
        if module_pom.is_file() and module_pom not in poms:
            poms.append(module_pom)
    return poms


def get_version_pins(pom_paths: list[Path]) -> PomScan:
    """Group every version-pinned artifact in the poms under the property that pins it.

    Artifacts without a version of their own are managed by an imported BOM and cannot be
    bumped here; those and any unresolvable declaration are summarised in the notes instead.
    """
    roots = [ET.parse(path).getroot() for path in pom_paths]
    # Module poms inherit the root pom's properties; a module's own definition wins.
    base_properties = get_properties(roots[0])
    # The reactor's own modules are not published; dependencies between them are skipped
    # rather than looked up.
    reactor = {c for c in (project_coordinate(root) for root in roots) if c is not None}

    pins: dict[str, Pin] = {}
    notes: list[str] = []
    all_properties: dict[str, str] = dict(base_properties)
    artifacts = 0
    managed = 0
    internal = 0

    for root in roots:
        properties = {**base_properties, **get_properties(root)}
        all_properties.update(properties)

        for element in root.iter():
            tag = element.tag.split("}")[-1]
            if tag not in COORDINATE_TAGS:
                continue

            raw_artifact = child_text(element, "artifactId")
            if raw_artifact is None:
                continue  # e.g. spotless' <eclipse> block, which is not a coordinate

            raw_version = child_text(element, "version")
            if raw_version is None:
                managed += 1  # version comes from an imported BOM or the parent; nothing to bump here
                continue

            raw_group = child_text(element, "groupId")
            if raw_group is None:
                if tag != "plugin":
                    continue
                raw_group = DEFAULT_PLUGIN_GROUP

            group = resolve(raw_group, properties)
            artifact = resolve(raw_artifact, properties)
            if group is None or artifact is None:
                notes.append(f"{raw_group}:{raw_artifact}:{raw_version}: unresolved property, skipped")
                continue

            coordinate = Coordinate(group, artifact)
            if coordinate in reactor:
                internal += 1
                continue

            version = resolve(raw_version, properties)
            if version is None:
                notes.append(f"{raw_group}:{raw_artifact}:{raw_version}: unresolved property, skipped")
                continue

            match = PLACEHOLDER.fullmatch(raw_version)
            # A hardcoded version has no property to bump, so the coordinate itself is the edit site.
            name = match.group(1) if match else str(coordinate)

            pin = pins.get(name)
            if pin is None:
                pins[name] = Pin(name, version, [coordinate], match is not None)
                artifacts += 1
            elif coordinate not in pin.coordinates:
                # The same property legitimately pins several artifacts; a differing version under
                # one name means a profile overrode the property, which changes what a bump means.
                if version != pin.version:
                    notes.append(f"{name} resolves to both {pin.version} and {version}, checking {pin.version}")
                pin.coordinates.append(coordinate)
                artifacts += 1

    if managed:
        notes.append(f"{managed} artifact(s) without an explicit version (managed by a BOM or the parent), skipped")
    if internal:
        notes.append(f"{internal} dependency declaration(s) on the project's own modules, skipped")

    unmapped = sorted(name for name in all_properties if name.endswith(".version") and name not in pins)
    return PomScan(sorted(pins.values()), artifacts, notes, unmapped)


def is_stable(version: str) -> bool:
    """True for purely numeric versions (ASCII digits); rejects 4.0.0-beta-4, 3.38.0.CR1, 26.0.alpha1, ..."""
    return all(chunk.isascii() and chunk.isdigit() for chunk in version.split("."))


def parse_version(version: str) -> tuple[int, ...]:
    """Parse a numeric version into a tuple of ints for ordered comparison."""
    return tuple(int(chunk) for chunk in version.split("."))


def repository() -> str:
    """The base URL to query: DEVKIT_MAVEN_MIRROR, validated as every Java target does, else Central."""
    mirror = os.environ.get("DEVKIT_MAVEN_MIRROR", "")
    if not mirror:
        return MAVEN_CENTRAL
    # Never printed: the checks keep a secret out of the URL that the header prints.
    if "@" in mirror:
        sys.exit(
            "ERROR: DEVKIT_MAVEN_MIRROR names a user or password (user@ or user:password@), "
            "which devkit would print; use a mirror that needs none"
        )
    if not MIRROR_URL.fullmatch(mirror):
        sys.exit(
            "ERROR: DEVKIT_MAVEN_MIRROR must be an https:// base URL with a host and no query, "
            "fragment or whitespace"
        )
    return mirror.removesuffix("/")


class HttpsOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only to https, as the pinned-Maven download does."""

    def redirect_request(self, req, fp, code, msg, headers, newurl) -> urllib.request.Request | None:
        if urllib.parse.urlsplit(newurl).scheme != "https":
            return None  # urllib then raises the 3xx as an HTTPError
        if fp is not None:
            fp.close()  # the base class then reads b"", not the redirect's whole (unbounded) body
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            # ProxyHandler re-adds it for a proxied host; a host in no_proxy must not get it.
            new.headers.pop("Proxy-authorization", None)
        return new


def refuse_doctype(content: bytes) -> None:
    """Raise ET.ParseError on a DOCTYPE (ElementTree expands internal entities), ExpatError on a malformed body."""

    def refuse(*_):
        raise ET.ParseError("DOCTYPE declared")

    parser = xml.parsers.expat.ParserCreate()
    parser.StartDoctypeDeclHandler = refuse
    parser.Parse(content, True)


class LookupTimeout(Exception):
    """The lookup's wall-clock deadline passed; not an OSError, which socket.create_connection would swallow."""


def lookup_timed_out(signum: int, frame: object) -> None:
    """SIGALRM handler: abandon the lookup in progress."""
    raise LookupTimeout(f"lookup timed out after {LOOKUP_DEADLINE}s")


signal.signal(signal.SIGALRM, lookup_timed_out)
OPENER = urllib.request.build_opener(HttpsOnlyRedirects)


def get_latest_version(base: str, group: str, artifact: str) -> str | None:
    """Return the newest stable version of an artifact in the repository at base, or None on failure.

    Central's <latest>/<release> markers routinely point at pre-releases (maven-compiler-plugin
    advertises 4.0.0-beta-4, quarkus-bom 3.38.0.CR1), which would report false upgrades, so the
    stable entries of <versions> decide. The markers are only a fallback for artifacts that
    publish no purely numeric version at all.
    """
    url = f"{base}/{group.replace('.', '/')}/{artifact}/maven-metadata.xml"
    try:
        signal.setitimer(signal.ITIMER_REAL, LOOKUP_DEADLINE)
        try:
            body = bytearray()
            with OPENER.open(url, timeout=REQUEST_TIMEOUT) as response:
                while chunk := response.read1(65536):  # chunks, so the size cap is checked as they arrive
                    body += chunk
                    if len(body) > MAX_METADATA_BYTES:
                        print(f"Error: {group}:{artifact} — metadata over {MAX_METADATA_BYTES} bytes, given up",
                              file=sys.stderr)
                        return None
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
        content = bytes(body)
    except urllib.error.HTTPError as exc:
        print(f"Error: status {exc.code} for {group}:{artifact}", file=sys.stderr)
        return None
    except (urllib.error.URLError, OSError, http.client.HTTPException, ValueError, LookupTimeout) as exc:
        print(f"Error: {group}:{artifact} — {str(exc)!r}", file=sys.stderr)
        return None

    try:
        refuse_doctype(content)
        versioning = ET.fromstring(content).find("versioning")
    # LookupError, ValueError: an unknown or multi-byte encoding declaration
    except (ET.ParseError, xml.parsers.expat.ExpatError, LookupError, ValueError) as exc:
        print(f"Error: {group}:{artifact} — malformed metadata ({str(exc)!r})", file=sys.stderr)
        return None
    if versioning is None:
        print(f"Error: {group}:{artifact} — metadata without <versioning>", file=sys.stderr)
        return None

    stable = [
        (candidate.text or "").strip()
        for candidate in versioning.iterfind("versions/version")
        if is_stable((candidate.text or "").strip())
    ]
    try:
        if stable:
            return max(stable, key=parse_version)

        for marker in ("release", "latest"):
            element = versioning.find(marker)
            latest = element.text.strip() if element is not None and element.text else ""
            if MARKER.fullmatch(latest):
                if is_stable(latest):
                    parse_version(latest)  # callers compare it numerically
                return latest
    except ValueError as exc:  # e.g. a version of over 4300 digits
        print(f"Error: {group}:{artifact} — unusable version in metadata ({exc})", file=sys.stderr)
        return None

    print(f"Error: {group}:{artifact} — no version found in metadata", file=sys.stderr)
    return None


def get_bump_target(pin: Pin, base: str) -> tuple[str | None, str, list[str]]:
    """Find the version to report for a pin, its status against the pin (compare()), and any notes.

    One property bumped to a version that not all of its artifacts have released would break
    the build, so the lowest of their latest releases wins (they usually agree), and a pin with
    an artifact that could not be checked gets no target at all. A latest that is no number (a
    non-numeric <release>/<latest> marker) orders against nothing: once the latests differ and
    one of them is no number, the pin is not compared, whatever its own version.
    """
    latest_per_artifact: dict[Coordinate, str] = {}
    for coordinate in pin.coordinates:
        latest = get_latest_version(base, coordinate.group, coordinate.artifact)
        if latest is None:
            return None, "unchecked", [f"could not check {coordinate}"]
        latest_per_artifact[coordinate] = latest

    candidates = list(latest_per_artifact.values())
    unnumbered = [version for version in candidates if not is_stable(version)]
    target = unnumbered[0] if unnumbered else min(candidates, key=parse_version)
    if len(set(candidates)) == 1:
        return target, compare(pin.version, target), []
    if unnumbered:
        listed = ", ".join(sorted(f"{coordinate} at {v}" for coordinate, v in latest_per_artifact.items()))
        return target, "unordered", [f"{pin.name} not compared, a latest release is not numeric: {listed}"]
    ahead = ", ".join(sorted(f"{coordinate} at {v}" for coordinate, v in latest_per_artifact.items() if v != target))
    note = f"{pin.name} held at {target} by its oldest artifact; newer available: {ahead}"
    return target, compare(pin.version, target), [note]


def compare(current: str, latest: str) -> str:
    """Classify a pinned version against the latest release (newest stable, else a <release>/<latest> marker's)."""
    if current == latest:
        return "current"
    if not is_stable(latest):
        return "unordered"  # a <release>/<latest> marker is no number to compare with
    if not is_stable(current):
        return "prerelease"  # pinned pre-release; numeric comparison would be misleading
    return "outdated" if parse_version(latest) > parse_version(current) else "ahead"


def describe(pin: Pin) -> str:
    """Render a pin's artifacts, dropping the groupId when it is shared by all of them."""
    if len(pin.coordinates) == 1:
        return str(pin.coordinates[0])
    groups = {coordinate.group for coordinate in pin.coordinates}
    if len(groups) == 1:
        return f"{groups.pop()}:({', '.join(c.artifact for c in pin.coordinates)})"
    return ", ".join(str(coordinate) for coordinate in pin.coordinates)


def main() -> None:
    if not POM_PATH.is_file():
        print(f"ERROR: {POM_PATH} not found.", file=sys.stderr)
        sys.exit(1)
    base = repository()

    scan = get_version_pins(find_pom_paths(POM_PATH))
    print(
        f"Checking {len(scan.pins)} version properties "
        f"({scan.artifact_count} artifacts) against {'Maven Central' if base == MAVEN_CENTRAL else base}...\n"
    )

    results: list[tuple[Pin, str, str]] = []  # pin, latest, status
    unchecked: list[Pin] = []
    notes = list(scan.notes)

    for pin in scan.pins:
        target, status, pin_notes = get_bump_target(pin, base)
        notes.extend(pin_notes)
        if target is None:
            unchecked.append(pin)
            continue
        results.append((pin, target, status))

    outdated = [entry for entry in results if entry[2] == "outdated"]
    if outdated:
        width = max(len(pin.name) for pin, _, _ in outdated)
        print(f"Outdated ({len(outdated)}):")
        for pin, target, _ in outdated:
            arrow = f"{pin.version} -> {target}"
            print(f"  {pin.name:<{width}}  {arrow:<22}  {describe(pin)}")
        print()

    print(f"Up to date: {sum(1 for entry in results if entry[2] == 'current')}")
    for pin, target, status in results:
        if status == "ahead":
            print(f"  {pin.name} pinned at {pin.version}, newer than the latest release {target}")
        elif status == "unordered":
            print(f"  {pin.name} pinned at {pin.version}, latest release {target} is not numeric, not compared")
        elif status == "prerelease":
            print(f"  {pin.name} pinned at pre-release {pin.version} (latest stable {target})")

    if unchecked:
        print(f"\nCould not check ({len(unchecked)}):")
        for pin in unchecked:
            print(f"  {pin.name} ({pin.version})")

    if notes or scan.unmapped_properties:
        print("\nNotes:")
        for note in notes:
            print(f"  {note}")
        for name in scan.unmapped_properties:
            print(f"  property {name} pins no Maven artifact, not checked")


if __name__ == "__main__":
    main()
