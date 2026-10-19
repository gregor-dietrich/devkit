#!/usr/bin/env python3
"""Judge a uv project's pip-audit reports against the advisories its devkit.toml accepts.

Usage: audit.py COMMAND, for the project at $PROJECT_ROOT (else the working directory):
  check-config                       validate devkit.toml's [[python.audit.accepted]] entries
  check-lock LOCK                    validate LOCK, the pylock.toml export of the runtime
                                     dependencies uv.lock pins, and print how many distinct
                                     (name, version) pins it holds
  judge LOCK [SERVICE RC REPORT]...  validate the entries and LOCK, then judge each
                                     pip-audit report (`-f json` output of the service
                                     SERVICE, which exited RC) against LOCK; no report at
                                     all when LOCK pins no package
A finding is a (package, version, advisory id) row in a report. An entry accepts it when its package
(PEP 503 normalized) is the finding's and its id, compared case-insensitively, is the finding's
id or one of its aliases; a finding two entries accept fails the run.
The run fails on every finding no entry accepts, and on every entry that no row of any report
matches (stale); staleness is judged only when every report was read. A report that is missing,
unreadable, holds a dependency pip-audit skipped, leaves out a package LOCK pins (compared as the
count of distinct versions per PEP 503 normalized name, so a name LOCK forks counts per version),
or comes with an exit status other than 0 and 1 (or 1 and no finding) fails the run. So does a LOCK
that cannot be read, whose lock-version is not 1.x, or that pins a package with no version or from
a git or URL source (pip-audit would audit it as the PyPI release of that name and version) or a
local file or directory source, and so does judging no report against a LOCK that pins packages.
Every failure is an ERROR line on stderr and exit 1 (a usage error exits 2); every report-judging
failure ends with one To fix line (a config failure, a LOCK failure and that no-report failure are
single ERRORs). A passing run lists each accepted finding on stdout. Every dependency of a report
carries a version, every advisory its aliases and fix_versions, as pip-audit writes them.
"""

import json
import os
import re
import sys
import tomllib
from pathlib import Path
from typing import Any, NamedTuple

# The sibling is found under -I, -P and PYTHONSAFEPATH too, which keep the script directory off sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from project_files import Failure, python_table

ROOT: Path = Path(os.environ.get("PROJECT_ROOT", ".")).resolve()
TABLE = "[python.audit] in devkit.toml"
ENTRY = "[[python.audit.accepted]]"
ACCEPTED = f"{ENTRY} in devkit.toml"
KEYS = {"accepted"}
ENTRY_KEYS = {"package", "id", "reason"}
PACKAGE_RE = re.compile(r"[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?")  # PEP 508 name
ID_RE = re.compile(r"[A-Za-z][A-Za-z0-9]*-[A-Za-z0-9.-]+")  # GHSA-..., PYSEC-..., CVE-...
EXAMPLE = '[[python.audit.accepted]]\npackage = "jinja2"\nid = "GHSA-xxxx-xxxx-xxxx"\nreason = "why it does not apply"'

Key = tuple[str, str]
SOURCES = {"vcs": "VCS", "archive": "URL", "directory": "local directory"}  # pylock keys of a non-PyPI source
LOCAL = " from a {} source, which pip-audit cannot audit against an index"
REMOTE = " from a {} source, which pip-audit would audit as the PyPI release of that name and version"


class Accepted(NamedTuple):
    package: str
    id: str
    reason: str


class Finding(NamedTuple):
    package: str
    version: str
    id: str
    aliases: tuple[str, ...]
    fixes: tuple[str, ...]


def normalize(name: str) -> str:
    """PEP 503: runs of -, _ and . are one -, case folded."""
    return re.sub(r"[-_.]+", "-", name).lower()


def accepted_entries(entries: Any) -> list[Accepted]:
    if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
        raise Failure(f"{ACCEPTED} must be an array of tables, each with package, id and reason, e.g.\n{EXAMPLE}")
    found: dict[Key, int] = {}
    result: list[Accepted] = []
    for number, entry in enumerate(entries, 1):
        if stray := sorted(set(entry) - ENTRY_KEYS):
            raise Failure(f"{ACCEPTED} entry {number} sets unknown key(s) {', '.join(stray)}; it reads only package, id and reason.")
        if missing := sorted(ENTRY_KEYS - set(entry)):
            raise Failure(f"{ACCEPTED} entry {number} sets no {', '.join(missing)}; it needs package, id and reason.")
        package, advisory, reason = (entry[key] for key in ("package", "id", "reason"))
        if not isinstance(package, str) or not PACKAGE_RE.fullmatch(package):
            raise Failure(f"{ACCEPTED} entry {number}: package must be a Python package name, not {package!r}.")
        if not isinstance(advisory, str) or not ID_RE.fullmatch(advisory):
            raise Failure(f"{ACCEPTED} entry {number} ({package}): id must be an advisory id such as GHSA-xxxx-xxxx-xxxx, PYSEC-2026-1 or CVE-2026-1, not {advisory!r}.")
        if not isinstance(reason, str) or not reason.strip():
            raise Failure(f"{ACCEPTED} entry {number} ({advisory} on {package}) needs a reason saying why the advisory is accepted.")
        key = (normalize(package), advisory.casefold())
        if key in found:
            raise Failure(f"{ACCEPTED} accepts {advisory} on {package} twice (entries {found[key]} and {number}); remove one.")
        found[key] = number
        result.append(Accepted(package, advisory, reason.strip()))
    return result


def config() -> list[Accepted]:
    python = python_table(ROOT)
    table = python.get("audit", {}) if isinstance(python, dict) else {}
    if not isinstance(table, dict):
        raise Failure(f"{TABLE} must be a table holding an accepted array.")
    if stray := sorted(set(table) - KEYS):
        raise Failure(f"{TABLE} sets unknown key(s) {', '.join(stray)}; it reads only accepted.")
    return accepted_entries(table.get("accepted", []))


def inventory(path: str) -> dict[str, set[str]]:
    """The versions per normalized name of the packages a pylock.toml pins; a Failure when it cannot be used."""
    try:
        lock = tomllib.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:  # TOMLDecodeError and UnicodeDecodeError both subclass it
        raise Failure(f"devkit cannot read the pylock.toml export of uv.lock ({exc}).") from exc
    declared = lock.get("lock-version")
    if not isinstance(declared, str) or declared.split(".")[0] != "1":
        raise Failure(f"the pylock.toml export of uv.lock has lock-version {declared!r}, not 1.x; its format changed under devkit.")
    packages = lock.get("packages")
    if packages is None:
        raise Failure("the pylock.toml export of uv.lock has no packages array; its format changed under devkit.")
    if not isinstance(packages, list) or not all(isinstance(package, dict) for package in packages):
        raise Failure("the pylock.toml export of uv.lock holds packages that are not an array of tables; its format changed under devkit.")
    found: dict[str, set[str]] = {}
    for package in packages:
        name, version = package.get("name"), package.get("version")
        if not isinstance(name, str):
            raise Failure("the pylock.toml export of uv.lock pins a package without a name; its format changed under devkit.")
        for key, kind in SOURCES.items():
            if key in package:
                table = package[key] if isinstance(package[key], dict) else {}
                if key == "archive" and "path" in table and "url" not in table:
                    kind = "local file"
                if key == "vcs" and isinstance(table.get("type"), str):
                    kind = table["type"]
                local = key == "directory" or kind == "local file"
                raise Failure(f"the pylock.toml export of uv.lock pins {name}{(LOCAL if local else REMOTE).format(kind)}; make audit cannot audit it.")
        if not isinstance(version, str):
            raise Failure(f"the pylock.toml export of uv.lock pins {name} with no version, which pip-audit cannot audit.")
        found.setdefault(normalize(name), set()).add(version)
    return found


def parse(service: str, rc: str, path: str) -> tuple[list[Finding], dict[str, set[str]]]:
    """The findings in one service's report and the versions it lists per normalized name; a Failure when the report cannot be judged."""
    where = f"pip-audit against {service}"
    if rc not in {"0", "1"}:
        raise Failure(f"{where} failed (exit {rc}); see its output above.")
    try:
        report = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:  # JSONDecodeError and UnicodeDecodeError both subclass it
        raise Failure(f"{where} (exit {rc}) left no readable report ({exc}); see its output above.") from exc
    dependencies = report.get("dependencies") if isinstance(report, dict) else None
    if not isinstance(dependencies, list):
        raise Failure(f"{where} reported no list of dependencies; its format changed under devkit.")
    found: list[Finding] = []
    listed: dict[str, set[str]] = {}
    for dependency in dependencies:
        if not isinstance(dependency, dict) or not isinstance(dependency.get("name"), str):
            raise Failure(f"{where} reported a dependency without a name; its format changed under devkit.")
        name = dependency["name"]
        if "skip_reason" in dependency:
            raise Failure(f"{where} could not audit {name}: {dependency['skip_reason']}")
        version = dependency.get("version")
        if not isinstance(version, str):
            raise Failure(f"{where} reported no version for {name}; its format changed under devkit.")
        listed.setdefault(normalize(name), set()).add(version)
        vulns = dependency.get("vulns")
        if not isinstance(vulns, list) or not all(isinstance(vuln, dict) for vuln in vulns):
            raise Failure(f"{where} reported no vulns list for {name} {version}; its format changed under devkit.")
        for vuln in vulns:
            aliases, fixes = vuln.get("aliases"), vuln.get("fix_versions")
            if not isinstance(vuln.get("id"), str) or not all(isinstance(item, list) and all(isinstance(x, str) for x in item) for item in (aliases, fixes)):
                raise Failure(f"{where} reported a malformed advisory for {name} {version}; its format changed under devkit.")
            found.append(Finding(name, version, vuln["id"], tuple(aliases), tuple(fixes)))
    if rc == "1" and not found:
        raise Failure(f"{where} failed (exit 1) but reported no advisory; see its output above.")
    return found, listed


def union(first: tuple[str, ...], second: tuple[str, ...]) -> tuple[str, ...]:
    """The items of both, first seen first, each once."""
    return tuple(dict.fromkeys(first + second))


def left_out(pinned: dict[str, set[str]], listed: dict[str, set[str]]) -> list[str]:
    """The "name version" pins of a name the report lists at fewer distinct versions than the lock pins."""
    missing: list[str] = []
    for name, versions in pinned.items():
        have = listed.get(name, set())
        missing += [f"{name} {version}" for version in versions - have] if len(versions) > len(have) else []
    return sorted(missing)


def judge(lock: str, reports: list[tuple[str, str, str]]) -> str:
    entries = config()
    pinned = inventory(lock)
    if pinned and not reports:
        n = sum(map(len, pinned.values()))
        raise Failure(f"devkit ran no pip-audit over the {n} package{'' if n == 1 else 's'} uv.lock pins.")
    failures: list[str] = []
    left, old = 0, False  # reports that leave out a locked package, and whether one exited other than 0 and 1
    rows: dict[tuple[str, str, str], tuple[Finding, list[str]]] = {}  # (package, version, id) -> finding, services
    for service, rc, path in reports:
        try:
            findings, listed = parse(service, rc, path)
            for finding in findings:
                key = (normalize(finding.package), finding.version, finding.id.casefold())
                known, services = rows.setdefault(key, (finding, []))
                # The services list one advisory with the aliases and fixes they know: keep the union.
                rows[key] = (known._replace(aliases=union(known.aliases, finding.aliases), fixes=union(known.fixes, finding.fixes)), services)
                if service not in services:
                    services.append(service)
            if missing := left_out(pinned, listed):
                left += 1
                failures.append(f"ERROR: pip-audit against {service} left out {', '.join(missing)} of the packages uv.lock pins.")
        except Failure as exc:
            failures.append(f"ERROR: {exc}")
            old |= rc not in {"0", "1"}
    unjudged = len(failures)

    def accepting(finding: Finding) -> list[Accepted]:
        return [e for e in entries if normalize(e.package) == normalize(finding.package) and e.id.casefold() in {x.casefold() for x in (finding.id, *finding.aliases)}]

    matched: set[Key] = set()
    unaccepted: list[str] = []
    ambiguous: list[str] = []
    accepted: list[str] = []
    for finding, services in sorted(rows.values()):
        accepters = accepting(finding)
        matched |= {(normalize(e.package), e.id.casefold()) for e in accepters}
        fixed = f"fixed in {', '.join(finding.fixes)}" if finding.fixes else "no fixed version"
        alias_text = f"aliases {', '.join(finding.aliases)}; " if finding.aliases else ""
        text = f"{finding.package} {finding.version}: {finding.id} ({alias_text}{fixed})"
        if len(accepters) > 1:
            ambiguous.append(f"ERROR: {text} is accepted by {len(accepters)} entries ({', '.join(e.id for e in accepters)}); keep one")
        elif accepters:
            accepted.append(f"  {text}: {accepters[0].reason}")
        else:
            unaccepted.append(f"ERROR: {text} reported by {' and '.join(sorted(services))}, not accepted in devkit.toml")
    stale = [] if unjudged else [e for e in entries if (normalize(e.package), e.id.casefold()) not in matched]
    failures += ["ERROR: staleness not judged: a pip-audit report " + ("could not be read." if unjudged > left else "left out a package uv.lock pins.")] if unjudged and entries else []
    failures += unaccepted + ambiguous
    audited = " or ".join(service for service, _, _ in reports)
    cause = f"no {audited} report holds it" if reports else "the project has no third-party runtime dependency"
    failures += [f"ERROR: stale {ENTRY} entry, {cause}: {e.id} on {e.package}" for e in stale]
    if failures:
        remedies = []
        if left:
            remedies.append("pin a pip-audit that audits every package of a pylock.toml, such as 2.10.1, the one devkit's fixtures pin: uv add --dev pip-audit==2.10.1, then make install")
        if unjudged > left:
            remedies.append("rerun make audit once pip-audit and the network work")
        if old:
            remedies.append("if pip-audit is too old for --aliases, --locked or --format json (it then exits 2), upgrade it with uv lock --upgrade-package pip-audit, then make install")
        if unaccepted:
            remedies.append(f"upgrade the package, or accept the advisory with an {ENTRY} entry in devkit.toml (package, id and a reason)")
        if ambiguous:
            remedies.append(f"keep one {ENTRY} entry per finding")
        if stale:
            remedies.append("remove the stale entries from devkit.toml")
        print("\n".join(failures), file=sys.stderr)
        print(f"To fix: {'; '.join(remedies)}.", file=sys.stderr)
        sys.exit(1)
    if accepted:
        print("Accepted advisories (devkit.toml):")
        print("\n".join(accepted))
    return f"pip-audit: no advisory beyond the {len(entries)} accepted." if reports else "No third-party runtime dependencies; no advisory accepted."


def main() -> None:
    try:
        match sys.argv[1:]:
            case ["check-config"]:
                count = len(config())
                print(f"[python.audit]: {count} accepted advisor{'y' if count == 1 else 'ies'}.")
            case ["check-lock", lock]:
                print(sum(map(len, inventory(lock).values())))
            case ["judge", lock, *rest] if len(rest) % 3 == 0:
                print(judge(lock, list(zip(rest[0::3], rest[1::3], rest[2::3]))))
            case _:
                print("usage: audit.py {check-config|check-lock LOCK|judge LOCK [SERVICE RC REPORT]...}", file=sys.stderr)
                sys.exit(2)
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
