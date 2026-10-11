#!/usr/bin/env python3
"""Judge one npm closure's `npm audit --json` report against its ignore file.

devkit's own `make audit` runs this through scripts/closure_audit.sh, once per pinned
closure (markdown/, jscpd/): closure_audit.py LABEL REPORT_JSON IGNORE_FILE. No consumer
target runs it. It runs no npm and needs no network; the report is a file.

The report fails closed: unless it is a JSON object with `"auditReportVersion": 2`
the verdict is a failure, whatever npm's exit status was. npm's own error object (an
`error` key, as when the registry is unreachable) fails naming its message.

An advisory is a dict in the `via` list of an entry of `vulnerabilities`; a string
there only points at another entry. Advisories are told apart by (package, GHSA id),
the id read from the advisory's `url`; one without a GHSA id there fails. Every
severity counts. So does a structure this cannot read: an entry that is not an object,
a `via` that is not a list, a string in it naming no entry, and a non-empty
`vulnerabilities` that yields no advisory at all all fail rather than being skipped.

IGNORE_FILE, which may be absent, holds one entry per line: a GHSA id, the package
the report carries it against and a justification, separated by whitespace. Blank
lines and lines starting with `#` are skipped. An advisory is ignored only by an
entry for its exact (package, id) pair. A malformed id, a missing package or
justification, a duplicate pair and a stale entry (a pair the report does not carry,
say after a lockfile bump fixed it) all fail, each naming the file and line.

Prints one line on stdout when the closure passes and one line per problem on stderr,
all of them before exiting; exits 1 on any problem.
"""

import json
import re
import sys
from pathlib import Path

REPORT_VERSION = 2
_ID = r"GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}"
_URL_ID_RE = re.compile(rf"/advisories/({_ID})/?$")  # a validator: .search
_IGNORE_ID_RE = re.compile(_ID)  # a validator: .fullmatch


def parse_report(report_text: str) -> tuple[dict | None, str | None]:
    """The report in `report_text`, or why it is not an npm audit report to judge."""
    try:
        report = json.loads(report_text)
    except ValueError:
        return None, "npm audit printed no JSON"
    if not isinstance(report, dict):
        return None, "npm audit printed JSON that is not an object"
    if "error" in report:
        error = report["error"] if isinstance(report["error"], dict) else {}
        message = report.get("message") or error.get("summary") or error.get("code") or "no reason given"
        return None, f"npm audit failed: {message}"
    if report.get("auditReportVersion") != REPORT_VERSION:
        return None, f"npm audit report version {report.get('auditReportVersion')!r}, want {REPORT_VERSION}"
    if not isinstance(report.get("vulnerabilities"), dict):
        return None, "npm audit report holds no vulnerabilities object"
    return report, None


def advisories(report: dict) -> tuple[dict[tuple[str, str], dict], list[str]]:
    """The report's advisories by (package, GHSA id), and a message per advisory without an id
    or part of the structure that cannot be read."""
    vulnerabilities = report["vulnerabilities"]
    found: dict[tuple[str, str], dict] = {}
    problems: list[str] = []
    for name, entry in vulnerabilities.items():
        if not isinstance(entry, dict):
            problems.append(f"{name}: the vulnerabilities entry is not an object")
            continue
        if not isinstance(entry.get("via"), list):
            problems.append(f"{name}: the vulnerabilities entry's via is not a list")
            continue
        for via in entry["via"]:
            if isinstance(via, str):  # names another entry
                if via not in vulnerabilities:
                    problems.append(f"{name}: via names '{via}', which is no vulnerabilities entry")
                continue
            if not isinstance(via, dict):
                problems.append(f"{name}: via holds {via!r}, neither an advisory nor an entry's name")
                continue
            package = str(via.get("name", "?"))
            match = _URL_ID_RE.search(str(via.get("url", "")))
            if match:
                found.setdefault((package, match.group(1)), via)
            else:
                text = f"{package}: advisory {via.get('source', '?')} has no GHSA id in its url ({via.get('url')!r})"
                if text not in problems:
                    problems.append(text)
    if vulnerabilities and not found and not problems:
        problems.append("the vulnerabilities hold no advisory")
    return found, problems


def read_ignores(path: Path) -> tuple[dict[tuple[str, str], int], list[str]]:
    """The ignored (package, GHSA id) pairs with their lines, and a message per malformed or
    duplicate entry."""
    ignored: dict[tuple[str, str], int] = {}
    problems: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return ignored, problems
    except (OSError, UnicodeDecodeError) as exc:
        return ignored, [f"cannot read {path}: {exc}"]
    for number, line in enumerate(lines, start=1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        ghsa, package, why = (text.split(None, 2) + ["", ""])[:3]
        where = f"{path}:{number}"
        if not _IGNORE_ID_RE.fullmatch(ghsa):
            problems.append(f"{where}: '{ghsa}' is not a GHSA id (GHSA-xxxx-xxxx-xxxx)")
            continue
        if not package:
            problems.append(f"{where}: {ghsa} has no package after the id")
            continue
        if (package, ghsa) in ignored:
            problems.append(f"{where}: {ghsa} on {package} is already ignored on line {ignored[(package, ghsa)]}")
            continue
        ignored[(package, ghsa)] = number  # even without a justification, so it is not also stale
        if not why:
            problems.append(f"{where}: {ghsa} on {package} has no justification after the package")
    return ignored, problems


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: closure_audit.py LABEL REPORT_JSON IGNORE_FILE", file=sys.stderr)
        return 2
    label, report_path, ignore_path = argv[1], Path(argv[2]), Path(argv[3])
    try:
        report_text = report_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        print(f"ERROR: {label}: cannot read the npm audit output: {exc}", file=sys.stderr)
        return 1
    report, why = parse_report(report_text)
    if report is None:
        print(f"ERROR: {label}: {why}", file=sys.stderr)
        return 1
    found, problems = advisories(report)
    ignored, ignore_problems = read_ignores(ignore_path)
    problems += ignore_problems
    problems += [
        f"{ignore_path}:{number}: {ghsa} on {package} is ignored but the report has no such advisory; remove the entry"
        for (package, ghsa), number in ignored.items()
        if (package, ghsa) not in found
    ]
    for (package, ghsa), via in sorted(found.items()):
        if (package, ghsa) not in ignored:
            problems.append(f"{package}: {ghsa} ({via.get('severity', '?')}) {via.get('title', '?')}")
    for problem in problems:
        print(f"ERROR: {label}: {problem}", file=sys.stderr)
    if problems:
        return 1
    count = len(ignored.keys() & found.keys())
    print(f"{label}: npm audit clean ({count} advisor{'y' if count == 1 else 'ies'} ignored)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
