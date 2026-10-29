#!/usr/bin/env python3
"""Name the test classes whose surefire or failsafe XML report (one path per stdin line) records a
failure or an error, or cannot be read: sorted, comma-separated, on one line."""

import sys
import xml.etree.ElementTree as ET


def verdict(path: str) -> str:
    """'' for a passing report, else its class, marked when the report cannot be read."""
    name = path.rsplit("/", 1)[-1].removeprefix("TEST-").removesuffix(".xml")
    try:
        attrs = ET.parse(path).getroot().attrib
        return name if int(attrs.get("failures", 0)) + int(attrs.get("errors", 0)) > 0 else ""
    except (OSError, ET.ParseError, ValueError):
        return f"{name} (unreadable report)"


def main() -> None:
    print(", ".join(sorted({v for p in sys.stdin.read().splitlines() if (v := verdict(p))})))


if __name__ == "__main__":
    main()
