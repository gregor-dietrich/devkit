#!/usr/bin/env python3
"""Hold one pytest session's coverage to COVERAGE_FLOOR.

Usage: coverage_floor.py JSON FLOOR LABEL
JSON is the report pytest-cov wrote (--cov-report=json:JSON, with --cov-branch), FLOOR a
percent from 0 to 100, LABEL the package the session tested, which every line names.
Prints one pass line; a failure is one ERROR line on stderr and exit 1; a malformed FLOOR
is one ERROR line and exit 2, a wrong argument count the usage and exit 2.
"""

import json
import re
import sys
from decimal import ROUND_DOWN, Decimal
from pathlib import Path
from typing import Any

# The same spelling scripts/python/check.sh accepts.
FLOOR = re.compile(r"100(\.0+)?|[0-9]{1,2}(\.[0-9]+)?")
CENT = Decimal("0.01")


class Failure(Exception):
    """A check that failed; its message is the ERROR line."""


def report(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            # Decimal, so a percent like 99.995 is compared and truncated exactly.
            data = json.load(handle, parse_float=Decimal)
    except FileNotFoundError as exc:
        raise Failure(
            "the pytest session wrote no coverage report; activate coverage in its pytest "
            "configuration (e.g. addopts --cov=<source>)"
        ) from exc
    except (OSError, ValueError) as exc:  # JSONDecodeError subclasses ValueError
        raise Failure(f"cannot read the coverage report {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise Failure(f"the coverage report {path} is not a JSON object")
    return data


def check(path: Path, floor: str) -> str:
    data = report(path)
    meta, totals = data.get("meta"), data.get("totals")
    if not isinstance(meta, dict) or meta.get("branch_coverage") is not True:
        raise Failure("the coverage report measured no branches; run pytest with --cov-branch")
    percent = totals.get("percent_covered") if isinstance(totals, dict) else None
    if isinstance(percent, bool) or not isinstance(percent, Decimal | int):
        raise Failure(f"the coverage report {path} has no totals.percent_covered")
    shown = Decimal(percent).quantize(CENT, rounding=ROUND_DOWN)
    if percent < Decimal(floor):
        raise Failure(f"coverage {shown}% is below COVERAGE_FLOOR {floor}%")
    return f"coverage {shown}% meets COVERAGE_FLOOR {floor}%"


def main() -> None:
    if len(sys.argv) != 4:
        print("usage: coverage_floor.py JSON FLOOR LABEL, FLOOR a percent from 0 to 100", file=sys.stderr)
        sys.exit(2)
    path, floor, label = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    if not FLOOR.fullmatch(floor):
        print(f"ERROR: COVERAGE_FLOOR '{floor}' is not a percent from 0 to 100; fix it in the project Makefile.", file=sys.stderr)
        sys.exit(2)
    try:
        print(f"{label}: {check(path, floor)}")
    except Failure as exc:
        print(f"ERROR: {label}: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
