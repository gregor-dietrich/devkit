#!/usr/bin/env python3
"""Print what devkit's uv scripts read from the project's uv.lock and pyproject.toml.

Usage: uv_project.py COMMAND, for the project at $PROJECT_ROOT (else the working directory):
  uv-version       the version of the uv package uv.lock pins
  uv-requirements  a pip requirements file for that uv: one --hash per locked wheel, for
                   pip's --require-hashes
  members          the project's packages as directories, sorted, one per line: each uv
                   workspace member as uv.lock records it, or "." for a single package
  vulture-paths    the root pyproject.toml's [tool.vulture] paths, one per line
Every failure is one ERROR line on stderr; exit 1.
"""

import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
# The pin names a cache directory and a requirements line, so it may hold neither "/" nor
# whitespace; PEP 440 versions need no more than these characters.
VERSION = re.compile(r"[0-9][0-9A-Za-z.+!-]*")
HASH = re.compile(r"sha256:[0-9a-f]{64}")
RELOCK = "add uv to the dev dependency group, then uv lock"


class Failure(Exception):
    """A read that failed; its message is the ERROR line."""


def load(name: str) -> dict[str, Any]:
    path = ROOT / name
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError as exc:
        raise Failure(f"no {name} in {ROOT}.") from exc
    except (OSError, ValueError) as exc:  # TOMLDecodeError subclasses ValueError
        raise Failure(f"cannot read {name}: {exc}") from exc


def packages(lock: dict[str, Any]) -> list[dict[str, Any]]:
    found = lock.get("package", [])
    if not isinstance(found, list) or not all(isinstance(package, dict) for package in found):
        raise Failure("uv.lock's [[package]] entries are not tables; regenerate it with uv lock.")
    return found


def uv_package(lock: dict[str, Any]) -> dict[str, Any]:
    """The one [[package]] entry named uv, with a version safe to use as a path and pin."""
    found = [package for package in packages(lock) if package.get("name") == "uv"]
    if not found:
        raise Failure(f"uv.lock pins no uv package; {RELOCK}.")
    if len(found) > 1:
        versions = ", ".join(str(package.get("version")) for package in found)
        raise Failure(f"uv.lock pins uv more than once ({versions}); constrain it to one version, then uv lock.")
    version = found[0].get("version")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise Failure(f"uv.lock's uv package has no usable version ({version!r}); {RELOCK}.")
    return found[0]


def uv_version() -> list[str]:
    return [uv_package(load("uv.lock"))["version"]]


def uv_requirements() -> list[str]:
    package = uv_package(load("uv.lock"))
    wheels = package.get("wheels", [])
    hashes = [w.get("hash") for w in wheels if isinstance(w, dict)] if isinstance(wheels, list) else []
    if not hashes or not all(isinstance(h, str) and HASH.fullmatch(h) for h in hashes):
        raise Failure(
            f"uv.lock records no sha256 hash for every uv {package['version']} wheel; "
            "pip cannot install it hash-verified. Regenerate the lock with uv lock."
        )
    return [f"uv=={package['version']} \\", *(f"    --hash={h} \\" for h in hashes[:-1]), f"    --hash={hashes[-1]}"]


def source_path(package: dict[str, Any]) -> str | None:
    """The directory of a project package: its editable or virtual source, else None."""
    source = package.get("source")
    if not isinstance(source, dict):
        return None
    path = source.get("editable", source.get("virtual"))
    return path if isinstance(path, str) else None


def members() -> list[str]:
    lock = load("uv.lock")
    by_name: dict[str, list[str]] = {}
    for package in packages(lock):
        if (path := source_path(package)) is not None:
            by_name.setdefault(str(package.get("name")), []).append(path)
    manifest = lock.get("manifest", {})
    names = manifest.get("members", []) if isinstance(manifest, dict) else None
    if not isinstance(names, list):
        raise Failure("uv.lock's [manifest] members is not a list; regenerate it with uv lock.")
    found: set[str] = set()
    for name in names:
        if name not in by_name:
            raise Failure(f"uv.lock lists workspace member {name} but no package entry for it; regenerate it with uv lock.")
        found.update(by_name[name])
    # A single project is no workspace member: its own package is the one at ".".
    if any("." in paths for paths in by_name.values()):
        found.add(".")
    if not found:
        raise Failure("uv.lock records no package of the project; regenerate it with uv lock.")
    if "." in found and len(found) > 1:
        raise Failure(
            "uv.lock records a package at the workspace root besides the members; "
            "make the root virtual (no [project] table), so every package is a member."
        )
    return sorted(found)


def vulture_paths() -> list[str]:
    tool = load("pyproject.toml").get("tool", {})
    vulture = tool.get("vulture", {}) if isinstance(tool, dict) else {}
    paths = vulture.get("paths") if isinstance(vulture, dict) else None
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
        raise Failure(
            'pyproject.toml sets no [tool.vulture] paths; list the directories vulture scans, e.g. paths = ["src", "tests"].'
        )
    return paths


COMMANDS = {
    "uv-version": uv_version,
    "uv-requirements": uv_requirements,
    "members": members,
    "vulture-paths": vulture_paths,
}


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: uv_project.py {{{'|'.join(COMMANDS)}}}", file=sys.stderr)
        sys.exit(2)
    try:
        print("\n".join(COMMANDS[sys.argv[1]]()))
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
