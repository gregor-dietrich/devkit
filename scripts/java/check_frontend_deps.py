#!/usr/bin/env python3
"""Verify committed frontend deps against the project's minimums and Vaadin's own version manifests.

Meant to run under make (lint.sh, install.sh), which sets MVN_CMD: the check asks that Maven for
the local repository and the frontend module's vaadin.version, and resolves the dev bundle with it.
"""

import json
import os
import re
import subprocess
import sys
import tomllib
import zipfile
import zlib
from pathlib import Path
from typing import Any, Dict, List, NoReturn, Optional, Set, Tuple, cast

# Repo root is the consuming project: $PROJECT_ROOT, which devkit's make includes
# export to every recipe, else the current working directory.
REPO_ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()

# Directory holding package.json, package-lock.json and the pom whose effective
# vaadin.version Maven reports. Single-module projects leave this at the repo root;
# multi-module ones pass the Vaadin module (e.g. "gui") as the first argument. Keeping
# the path a parameter is what lets one copy of this file serve both layouts.
FRONTEND_DIR: Path = REPO_ROOT / (sys.argv[1] if len(sys.argv) > 1 else ".")

# A concrete dotted version (e.g. "25.2.0"); excludes npm "$ref" overrides and "$var".
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+")

# Minimums accept stable releases only: a prerelease such as "3.4.16-rc.1" sorts below its release
# and may lack the fix, but parse_version() would rank it at or above the minimum.
STABLE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

# Location of the core versions manifest inside vaadin-core-internal, newest layout first:
# Vaadin 25.3 moved it from the jar root into META-INF/VAADIN/versions/.
CORE_MANIFEST_MEMBERS: Tuple[str, ...] = (
    "META-INF/VAADIN/versions/vaadin-core-versions.json",
    "vaadin-core-versions.json",
)

# The bundle jar whose package-lock.json carries the versions vaadin-core-versions.json omits.
# Vaadin's dev mode resolves it, but no gate's build does, so the check resolves it itself. The
# prod bundle, which a build does resolve, carries no package-lock.json (Vaadin 25.0–25.3: only
# config/stats.json).
BUNDLE_ARTIFACT = "vaadin-dev-bundle"

# Pinned rather than "help:evaluate": the bare prefix resolves the plugin's latest release from
# repository metadata, which floats and is re-fetched daily.
HELP_EVALUATE = "org.apache.maven.plugins:maven-help-plugin:3.5.2:evaluate"
# Pinned for the same reason: Maven 3.10's super POM no longer manages maven-dependency-plugin.
DEPENDENCY_GET = "org.apache.maven.plugins:maven-dependency-plugin:3.11.0:get"

# Upper bound for one Maven call; resolving the dev bundle downloads it on first use.
MAVEN_TIMEOUT = 600

# Remedy printed when a @vaadin/* component has drifted off its manifest version.
REGEN_HINT = (
    "Regenerate the committed frontend files at the pinned Vaadin version (a Vaadin build-frontend run), "
    "or move <vaadin.version> to the version they were generated from."
)


def load_min_pins(toml_path: Path) -> Dict[str, str]:
    """Read the project's npm minimums, "<npm-package>" = "<min>", from [frontend.min-pins].

    The project names the security-sensitive packages that Vaadin's frontend generator can
    silently re-pin below a safe minimum on rebuild. Fails closed: a missing file or table is
    an error; an empty table declares none.
    """
    table = f"[frontend.min-pins] in {toml_path}"
    remedy = (
        "List the project's npm minimums there (an empty table declares none); "
        "when upgrading from v0.1.x, see .devkit/README.md."
    )
    if not toml_path.is_file():
        raise ValueError(f"Missing {table}: no such file. {remedy}")
    try:
        with toml_path.open("rb") as handle:
            frontend = tomllib.load(handle).get("frontend")
    except ValueError as exc:  # TOMLDecodeError and UnicodeDecodeError both subclass it
        raise ValueError(f"{toml_path} is not valid TOML: {exc}") from exc
    if not isinstance(frontend, dict) or "min-pins" not in frontend:
        raise ValueError(f"Missing {table}. {remedy}")
    frontend_map = cast(Dict[str, Any], frontend)
    stray = sorted(key for key in frontend_map if key != "min-pins")
    if stray:
        raise ValueError(
            f"Unknown key(s) under [frontend] in {toml_path}: {', '.join(stray)}; only [frontend.min-pins] is read."
        )
    pins = frontend_map["min-pins"]
    if not isinstance(pins, dict):
        raise ValueError(f"{table} must be a table.")
    pins_map = cast(Dict[str, Any], pins)
    for pkg, minimum in pins_map.items():
        # An unquoted dotted name (chart.js = "1.2.3") parses as a TOML dotted key: a nested table.
        if isinstance(minimum, dict):
            raise ValueError(f'{pkg}.* in {table} is a table: quote package names that contain ".", "@" or "/".')
        if not isinstance(minimum, str) or not STABLE.match(minimum):
            raise ValueError(f"{pkg} = {json.dumps(minimum, default=str)} in {table} is not a stable x.y.z version.")
    return cast(Dict[str, str], pins_map)


def maven_cmd() -> str:
    """Return the Maven command make's scripts export as MVN_CMD (get_maven.sh)."""
    mvn = os.environ.get("MVN_CMD")
    if not mvn:
        raise LookupError("MVN_CMD is not set: run this check through make (make lint or make install).")
    return mvn


def maven_evaluate(expression: str, *args: str) -> str:
    """Ask Maven, run from REPO_ROOT without recursing into modules, for an expression's effective value.

    -B keeps ANSI colour out of the answer and of the error lines -q still prints.
    """
    command = [maven_cmd(), "-B", "-q", "-N", HELP_EVALUATE, f"-Dexpression={expression}", "-DforceStdout", *args]
    result = subprocess.run(command, cwd=REPO_ROOT, capture_output=True, text=True, timeout=MAVEN_TIMEOUT, check=False)
    if result.returncode != 0:
        output = (result.stdout + result.stderr).strip()
        raise ValueError(f"Maven failed to evaluate {expression} (exit {result.returncode}):\n{output}")
    return result.stdout.strip()


def read_vaadin_version() -> str:
    """Return the frontend module's effective vaadin.version as Maven reports it."""
    pom = FRONTEND_DIR / "pom.xml"
    version = maven_evaluate("vaadin.version", "-f", str(pom))
    if not STABLE.match(version):
        raise ValueError(f'Maven reports vaadin.version as "{version}" for {pom}, not an x.y.z version.')
    return version


def maven_local_repo() -> Path:
    """Return Maven's effective local repository (settings, -Dmaven.repo.local, .mvn/maven.config)."""
    repo = maven_evaluate("settings.localRepository")
    path = REPO_ROOT / repo
    if not repo or not path.is_dir():
        raise ValueError(f'Maven reports the local repository as "{repo}", which is not a directory.')
    return path


def load_json(path: Path) -> Any:
    """Read a JSON file, naming it when it does not parse."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:  # JSONDecodeError and UnicodeDecodeError both subclass it
        raise ValueError(f"{path} is not valid JSON: {exc}") from exc


def collect_manifest_versions(obj: Any, out: Dict[str, str]) -> None:
    """Recursively record npmName -> jsVersion pairs from a Vaadin versions manifest."""
    if isinstance(obj, dict):
        mapping = cast(Dict[str, Any], obj)
        npm = mapping.get("npmName")
        js = mapping.get("jsVersion")
        if isinstance(npm, str) and isinstance(js, str):
            out.setdefault(npm, js)
        for value in mapping.values():
            collect_manifest_versions(value, out)
    elif isinstance(obj, list):
        for value in cast(List[Any], obj):
            collect_manifest_versions(value, out)


def load_bundle_versions(jar_path: Path, out: Dict[str, str]) -> None:
    """Fill in @vaadin/* versions from a Vaadin bundle jar's package-lock.json (gaps only)."""
    with zipfile.ZipFile(jar_path) as jar:
        members = [n for n in jar.namelist() if n.endswith("/package-lock.json") and "node_modules" not in n]
        if not members:
            raise LookupError(f"No package-lock.json found in {jar_path}.")
        lock = json.loads(jar.read(members[0]))
    packages = lock.get("packages") if isinstance(lock, dict) else None
    seen = 0
    if isinstance(packages, dict):
        for key, raw_entry in cast(Dict[str, Any], packages).items():
            name = key.split("node_modules/")[-1]
            if name.startswith("@vaadin/") and isinstance(raw_entry, dict):
                version = cast(Dict[str, Any], raw_entry).get("version")
                if isinstance(version, str):
                    out.setdefault(name, version)
                    seen += 1
    # A lock without one @vaadin/ entry means the bundle's format changed under the check.
    if not seen:
        raise LookupError(f"The package-lock.json in {jar_path} lists no @vaadin/ package.")


def vaadin_jar(repo: Path, artifact: str, version: str) -> Path:
    """Return where the local repository keeps com.vaadin:<artifact>:<version>."""
    return repo / "com" / "vaadin" / artifact / version / f"{artifact}-{version}.jar"


def load_expected_versions(repo: Path, version: str) -> Dict[str, str]:
    """Build the authoritative npmName -> version map from resolved Vaadin jars."""
    core_jar = vaadin_jar(repo, "vaadin-core-internal", version)
    if not core_jar.is_file():
        raise FileNotFoundError(
            f"Vaadin manifest jar not found: {core_jar}\n"
            "Run 'mvn compile' or 'make install' first so the Vaadin jars are resolved locally."
        )
    expected: Dict[str, str] = {}
    with zipfile.ZipFile(core_jar) as jar:
        names = set(jar.namelist())
        member = next((m for m in CORE_MANIFEST_MEMBERS if m in names), None)
        if member is None:
            raise LookupError(f"None of {list(CORE_MANIFEST_MEMBERS)} found in {core_jar}.")
        collect_manifest_versions(json.loads(jar.read(member)), expected)

    # A few @vaadin/* packages (e.g. common-frontend, vaadin-themable-mixin) are shipped
    # by Vaadin but omitted from vaadin-core-versions.json. Vaadin's dev bundle jar
    # carries their resolved versions; use it to fill the gaps (core manifest still wins).
    load_bundle_versions(find_bundle_jar(repo, version), expected)
    return expected


def find_bundle_jar(repo: Path, version: str) -> Path:
    """Return the Vaadin dev bundle jar, resolving it through Maven (MVN_CMD) if it is missing."""
    jar = vaadin_jar(repo, BUNDLE_ARTIFACT, version)
    if jar.is_file():
        return jar
    resolve = ["-N", DEPENDENCY_GET, f"-Dartifact=com.vaadin:{BUNDLE_ARTIFACT}:{version}", "-Dtransitive=false"]
    print(f"Resolving {BUNDLE_ARTIFACT} {version}...", flush=True)
    subprocess.run([maven_cmd(), "-q", *resolve], cwd=REPO_ROOT, timeout=MAVEN_TIMEOUT, check=False)
    if not jar.is_file():
        raise FileNotFoundError(
            f"Vaadin bundle jar not found: {jar}\n"
            f"It carries the @vaadin/* versions the core manifest omits. Resolve it with 'mvn {' '.join(resolve)}'."
        )
    return jar


def collect_pkg_json_vaadin(obj: Any, out: Dict[str, Set[str]]) -> None:
    """Recursively collect concrete @vaadin/* version declarations from package.json."""
    if isinstance(obj, dict):
        mapping = cast(Dict[str, Any], obj)
        for key, value in mapping.items():
            if isinstance(value, str) and key.startswith("@vaadin/") and SEMVER.match(value):
                out.setdefault(key, set()).add(value)
            else:
                collect_pkg_json_vaadin(value, out)
    elif isinstance(obj, list):
        for value in cast(List[Any], obj):
            collect_pkg_json_vaadin(value, out)


def collect_pkg_json_pin(obj: Any, pkg: str, out: Set[str]) -> None:
    """Recursively collect concrete version declarations for a specific package name."""
    if isinstance(obj, dict):
        mapping = cast(Dict[str, Any], obj)
        for key, value in mapping.items():
            if key == pkg and isinstance(value, str) and SEMVER.match(value):
                out.add(value)
            else:
                collect_pkg_json_pin(value, pkg, out)
    elif isinstance(obj, list):
        for value in cast(List[Any], obj):
            collect_pkg_json_pin(value, pkg, out)


def collect_lock_versions(lock: Dict[str, Any], prefix: str) -> Dict[str, Set[str]]:
    """Collect resolved versions from package-lock.json for packages under a name prefix."""
    out: Dict[str, Set[str]] = {}
    packages = lock.get("packages", {})
    if isinstance(packages, dict):
        packages_map = cast(Dict[str, Any], packages)
        for key, raw_entry in packages_map.items():
            name = key.split("node_modules/")[-1]
            if name.startswith(prefix) and isinstance(raw_entry, dict):
                entry = cast(Dict[str, Any], raw_entry)
                version = entry.get("version")
                if isinstance(version, str):
                    out.setdefault(name, set()).add(version)
    return out


def parse_version(value: str) -> Tuple[int, ...]:
    """Parse a dotted version string into a tuple of integers for ordered comparison."""
    parts: List[int] = []
    for chunk in value.split("."):
        digits = re.match(r"[0-9]+", chunk)
        parts.append(int(digits.group(0)) if digits else 0)
    return tuple(parts)


def check_min_pins(
    min_pins: Dict[str, str], pkg_json: Dict[str, Any], pkg_lock: Optional[Dict[str, Any]]
) -> List[str]:
    """Check that the project's pinned packages meet their minimum version in both files."""
    errors: List[str] = []
    for pkg, minimum in min_pins.items():
        json_versions: Set[str] = set()
        collect_pkg_json_pin(pkg_json, pkg, json_versions)
        if not json_versions:
            errors.append(f"{pkg} missing version in package.json (require >= {minimum}).")
        for found in sorted(json_versions):
            if not STABLE.match(found) or parse_version(found) < parse_version(minimum):
                errors.append(f"{pkg} is {found} in package.json (require stable >= {minimum}).")

        if pkg_lock is not None:
            lock_versions = collect_lock_versions(pkg_lock, pkg).get(pkg, set())
            if not lock_versions:
                errors.append(f"{pkg} missing version in package-lock.json (require >= {minimum}).")
            for found in sorted(lock_versions):
                if not STABLE.match(found) or parse_version(found) < parse_version(minimum):
                    errors.append(f"{pkg} is {found} in package-lock.json (require stable >= {minimum}).")
    return errors


def check_vaadin_versions(
    label: str, found: Dict[str, Set[str]], expected: Dict[str, str]
) -> Tuple[List[str], bool]:
    """Check that every @vaadin/* version matches Vaadin's manifest; returns (errors, drift)."""
    errors: List[str] = []
    drift = False
    for pkg in sorted(found):
        for version in sorted(found[pkg]):
            if pkg not in expected:
                errors.append(f"{pkg} ({version}) in {label} has no entry in the Vaadin version manifest.")
            elif version != expected[pkg]:
                errors.append(f"{pkg} is {version} in {label}, expected {expected[pkg]} per the Vaadin manifest.")
                drift = True
    return errors, drift


def fail(errors: List[str], drift: bool = False) -> NoReturn:
    """Print each error (and the regeneration remedy on drift), then exit 1."""
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if drift:
        print(f"       {REGEN_HINT}", file=sys.stderr)
    print("Frontend dependency check FAILED.", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    errors: List[str] = []
    drift = False

    pkg_json_path = FRONTEND_DIR / "package.json"
    pkg_lock_path = FRONTEND_DIR / "package-lock.json"

    print("Checking pinned frontend dependencies...", flush=True)
    try:
        min_pins = load_min_pins(REPO_ROOT / "devkit.toml")
    except (ValueError, OSError) as exc:
        fail([str(exc)])

    try:
        pkg_json: Dict[str, Any] = load_json(pkg_json_path)
        pkg_lock: Optional[Dict[str, Any]] = None
        if pkg_lock_path.is_file():
            pkg_lock = load_json(pkg_lock_path)
            if not isinstance(pkg_lock, dict):
                raise ValueError(f"{pkg_lock_path} is not a JSON object.")
    except (OSError, ValueError) as exc:
        fail([*errors, str(exc)])

    # Check 1: the project's security-sensitive minimum version pins.
    errors.extend(check_min_pins(min_pins, pkg_json, pkg_lock))

    # Check 2: @vaadin/* components must match Vaadin's own version manifest.
    try:
        # Two help:evaluate calls, ~10 s on a real multi-module consumer. One joined expression
        # took ~6 s, but works only because Maven interpolates -Dexpression twice: undocumented.
        version = read_vaadin_version()
        print(f"Verifying @vaadin/* components against Vaadin {version} manifest...", flush=True)
        expected = load_expected_versions(maven_local_repo(), version)
    except (
        OSError,
        ValueError,
        LookupError,
        EOFError,
        RuntimeError,  # NotImplementedError among them: a jar member compressed in an unsupported way
        zipfile.BadZipFile,
        zlib.error,
        subprocess.SubprocessError,
    ) as exc:
        fail([*errors, str(exc)])

    json_vaadin: Dict[str, Set[str]] = {}
    collect_pkg_json_vaadin(pkg_json, json_vaadin)
    json_errors, json_drift = check_vaadin_versions("package.json", json_vaadin, expected)
    errors.extend(json_errors)
    drift = drift or json_drift

    if pkg_lock is not None:
        lock_vaadin = collect_lock_versions(pkg_lock, "@vaadin/")
        lock_errors, lock_drift = check_vaadin_versions("package-lock.json", lock_vaadin, expected)
        errors.extend(lock_errors)
        drift = drift or lock_drift

    if errors:
        fail(errors, drift)

    print("Frontend dependency check passed.")


if __name__ == "__main__":
    main()
