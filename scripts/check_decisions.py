#!/usr/bin/env python3
"""Check the entry format of the project's decisions log, docs/decisions.md.

`make lint-decisions` runs this in $PROJECT_ROOT, as docs/contract.md describes. A
project without docs/decisions.md is skipped. An entry is a `## ADR-<digits>` heading
and the lines up to the next `## ` heading; entries below a `## Superseded` heading
are retired, and another heading naming an ADR fails. Each entry carries exactly one
`**Status:** ` marker, whose value is `Accepted` or `Proposed` on an active entry. An
entry with a line starting `**Premise:**` carries one line starting `**Guard:**` whose
first word names how the premise is watched (GUARD_CLASSES); a `cascade` guard names
`trigger: tag:<tag>` in its paragraph, and an active entry whose tag exists is spent.
An entry has at most one `**Premise:**` and one `**Guard:**` line; a line leading with
`- ` quotes either label without being read as one. Fenced code blocks are not read,
and one that never closes fails.

Tags are read once from git and compared here, so no text of the log reaches git's
command line. A shallow clone has incomplete tags, so it fails when an active cascade
names a trigger.

Prints a census line on stdout and one line per violation on stderr; exits 1 on any
violation, and on an unreadable log or a git error, which is one ERROR line.
"""

import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

LOG = "docs/decisions.md"
GUARD_CLASSES = ("watcher", "cascade", "memory-only")
STATUS_WORDS = ("Accepted", "Proposed")
_ENTRY_RE = re.compile(r"## (ADR-\d+)\b")  # a validator: .match
_SUPERSEDED_RE = re.compile(r"## Superseded\b", re.IGNORECASE)  # a validator: .match
_STATUS_RE = re.compile(r"\*\*Status:\*\* +(\S*)")  # a scan: .finditer
_TRIGGER_RE = re.compile(r"\btrigger:\s*(\S+)")  # a scan: .search
_WORD_RE = re.compile(r"[\w-]+")  # a word, so punctuation after it is not part of it: .match
# A heading naming an ADR, which must then be an entry heading (_ENTRY_RE). A validator: .match
_ADR_HEADING_RE = re.compile(r" {0,3}#{2,}.*ADR-\d")
# A code fence: three or more backticks or tildes after at most three spaces. A validator: .match
_FENCE_RE = re.compile(r" {0,3}(`{3,}|~{3,})")
_CLASSES = "watcher, cascade or memory-only"
_PREMISE = "**Premise:**"
_GUARD = "**Guard:**"
_TAG = "tag:"


@dataclass
class Entry:
    """One `## ADR-<digits>` entry: its heading line and what it carries, by line."""

    adr: str
    line: int
    retired: bool
    statuses: list[tuple[int, str]] = field(default_factory=list)  # (line, value) per marker
    premises: list[int] = field(default_factory=list)
    guards: list[tuple[int, str]] = field(default_factory=list)  # (line, paragraph after the label)

    @property
    def guard_word(self) -> str:
        """The first word of the entry's one guard paragraph; empty without exactly one."""
        found = _WORD_RE.match(self.guards[0][1].lstrip()) if len(self.guards) == 1 else None
        return found.group() if found else ""

    @property
    def guard_class(self) -> str | None:
        return self.guard_word if self.guard_word in GUARD_CLASSES else None

    @property
    def trigger(self) -> str | None:
        """The `trigger:` value in the entry's one guard paragraph, trailing punctuation dropped."""
        found = _TRIGGER_RE.search(self.guards[0][1]) if len(self.guards) == 1 else None
        return found.group(1).rstrip(".,;)").strip("`") if found else None


@dataclass(frozen=True)
class Violation:
    line: int
    message: str

    def __str__(self) -> str:
        return f"{LOG}:{self.line}: {self.message}"


class Failure(Exception):
    """A failure that stops the check; its message is the ERROR line."""


def _lines(text: str) -> list[str]:
    return text.replace("\r\n", "\n").split("\n")


def _read_fences(lines: list[str]) -> tuple[list[tuple[int, str]], int | None]:
    """(line number, line) for every line outside a fenced code block, the fences
    excluded, and the opening line of a fence that never closes. A fence closes at a run
    of its own character at least as long, alone on its line, as in CommonMark; an
    unclosed one runs to the end."""
    live: list[tuple[int, str]] = []
    fence, opened = "", 0
    for lineno, line in enumerate(lines, start=1):
        run = _FENCE_RE.match(line)
        if not fence:
            if run:
                fence, opened = run.group(1), lineno
            else:
                live.append((lineno, line))
        elif run and run.group(1)[0] == fence[0] and len(run.group(1)) >= len(fence) and not line[run.end() :].strip():
            fence = ""
    return live, opened if fence else None


def parse_entries(text: str) -> list[Entry]:
    """Every entry in a decisions log, in order, read from the lines outside fenced code
    blocks. A guard paragraph runs from its `**Guard:**` line to the next blank line,
    heading or fence, so a wrapped `trigger:` is read."""
    lines = _lines(text)
    entries: list[Entry] = []
    entry: Entry | None = None
    retired = False
    for lineno, line in _read_fences(lines)[0]:
        if line.startswith("## "):
            retired = retired or _SUPERSEDED_RE.match(line) is not None
            heading = _ENTRY_RE.match(line)
            entry = Entry(heading.group(1), lineno, retired) if heading else None
            if entry is not None:
                entries.append(entry)
        if entry is None:
            continue
        entry.statuses += [(lineno, marker.group(1)) for marker in _STATUS_RE.finditer(line)]
        if line.startswith(_PREMISE):
            entry.premises.append(lineno)
        elif line.startswith(_GUARD):
            paragraph = [line.removeprefix(_GUARD)]
            for after in lines[lineno:]:
                if not after.strip() or after.startswith("## ") or _FENCE_RE.match(after):
                    break
                paragraph.append(after)
            entry.guards.append((lineno, " ".join(paragraph)))
    return entries


def _entry_violations(entry: Entry, fired: set[str]) -> list[Violation]:
    adr = entry.adr
    out: list[Violation] = []
    if len(entry.statuses) != 1:
        out.append(
            Violation(
                entry.line,
                f"{adr} carries {len(entry.statuses)} '**Status:** ' markers where exactly one is "
                "required: its status is read from that marker",
            )
        )
    out += [
        Violation(
            line,
            f"{adr} has the status {value!r}: an active entry is 'Accepted' or 'Proposed', spelled "
            "exactly; move a retired one under the '## Superseded' heading",
        )
        for line, value in entry.statuses
        if not entry.retired and value not in STATUS_WORDS
    ]
    for label, count in ((_PREMISE, len(entry.premises)), (_GUARD, len(entry.guards))):
        if count > 1:
            out.append(
                Violation(
                    entry.line,
                    f"{adr} has {count} lines starting with '{label}' where at most one is read; "
                    "lead a quoted one with '- '",
                )
            )
    if not entry.premises or len(entry.guards) > 1:
        return out
    if not entry.guards:
        out.append(
            Violation(
                entry.premises[0],
                f"{adr} has a '{_PREMISE}' but no '{_GUARD}' line: name how the premise is watched: {_CLASSES}",
            )
        )
        return out
    guard_line = entry.guards[0][0]
    if entry.guard_class is None:
        out.append(
            Violation(
                guard_line,
                f"{adr}'s '{_GUARD}' starts with {entry.guard_word!r} where one of {_CLASSES} is required",
            )
        )
    elif entry.guard_class == "cascade":
        trigger = entry.trigger
        if trigger is not None and "`" in trigger:
            out.append(
                Violation(
                    guard_line,
                    f"{adr}'s trigger {trigger!r} holds a backtick, which would be read as part of the "
                    "tag's name; put backticks around the whole value or none",
                )
            )
        elif trigger is None or not trigger.startswith(_TAG) or trigger == _TAG:
            found = "none" if trigger is None else repr(trigger)
            out.append(
                Violation(
                    guard_line,
                    f"{adr}'s cascade guard names no 'trigger: tag:<tag>' (found {found}): the tag "
                    "is what tells when the premise is spent",
                )
            )
        elif not entry.retired and trigger in fired:
            out.append(
                Violation(
                    guard_line,
                    f"{adr} is spent: its trigger {trigger!r} exists, so its premise no longer holds; "
                    "move it under the '## Superseded' heading with a status saying why",
                )
            )
    return out


def check(text: str, fired: set[str]) -> list[Violation]:
    """Every violation in a decisions log, given the `tag:<tag>` triggers that have fired."""
    live, unclosed = _read_fences(_lines(text))
    found = [
        Violation(
            lineno, f"{line.strip()!r} is not an entry heading: use '## ADR-<digits>', or the entry goes unchecked"
        )
        for lineno, line in live
        if _ADR_HEADING_RE.match(line) and not _ENTRY_RE.match(line)
    ]
    if unclosed is not None:
        found.append(
            Violation(unclosed, "a code fence opened here never closes, so every entry after it goes unchecked")
        )
    return found + [violation for entry in parse_entries(text) for violation in _entry_violations(entry, fired)]


def _git(root: Path, *args: str) -> str:
    try:
        run = subprocess.run(["git", *args], cwd=root, capture_output=True, check=False)
    except OSError as exc:
        raise Failure(f"cannot run git to read the repository's tags: {exc.strerror}") from exc
    if run.returncode != 0:
        reason = run.stderr.decode(errors="replace").strip().splitlines()
        raise Failure(f"git cannot read the tags in {root}: {reason[0] if reason else 'git failed'}")
    return run.stdout.decode(errors="replace")


def fired_triggers(root: Path, entries: list[Entry]) -> set[str]:
    """The `tag:<tag>` triggers of the active cascade guards among *entries* whose tag
    exists in *root*, the only ones that can make an entry spent.

    No git call when none names one. Raises Failure when git fails, and on a shallow
    clone, whose tags are incomplete.
    """
    triggers = {
        trigger
        for entry in entries
        if not entry.retired and entry.premises and entry.guard_class == "cascade"
        if (trigger := entry.trigger) and trigger.startswith(_TAG)
    }
    if not triggers:
        return set()
    if _git(root, "rev-parse", "--is-shallow-repository").strip() != "false":
        raise Failure(
            f"{root} is a shallow clone, whose tags are incomplete, and an active cascade in {LOG} "
            "names a trigger; fetch the full history and its tags (in CI, a checkout with fetch-depth 0)"
        )
    tags = _git(root, "for-each-ref", "--format=%(refname:strip=2)", "refs/tags").splitlines()
    return triggers & {_TAG + tag for tag in tags}


def census(entries: list[Entry]) -> str:
    guarded = [entry for entry in entries if entry.premises]
    active = [entry for entry in guarded if not entry.retired]
    by_class = ", ".join(f"{sum(e.guard_class == name for e in active)} {name}" for name in GUARD_CLASSES)
    return (
        f"decisions log: {len(entries)} {'entry' if len(entries) == 1 else 'entries'}; premise guards: {len(active)} active ({by_class}), "
        f"{len(guarded) - len(active)} retired"
    )


def main() -> None:
    root = Path(os.environ.get("PROJECT_ROOT") or ".").resolve()
    path = root / LOG
    if not os.path.lexists(path):
        print(f"lint-decisions: no {LOG}; skipped.")
        return
    try:
        try:
            # Bytes, not read_text: universal newlines would move the line numbers.
            text = path.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise Failure(f"cannot read {LOG}: {exc.strerror if isinstance(exc, OSError) else 'not UTF-8'}") from exc
        entries = parse_entries(text)
        fired = fired_triggers(root, entries)
    except Failure as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    violations = check(text, fired)
    print(census(entries), flush=True)
    for violation in sorted(violations, key=lambda v: v.line):
        print(violation, file=sys.stderr)
    if violations:
        sys.exit(1)


if __name__ == "__main__":
    main()
