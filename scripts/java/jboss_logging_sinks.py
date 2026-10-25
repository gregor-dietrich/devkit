#!/usr/bin/env python3
"""Generate and check java/config/findsecbugs-crlf-jboss-logging.txt.

The file lists the JBoss Logging methods find-sec-bugs treats as log-injection sinks, one
`owner.method(descriptor)V:i,j,...` line each; find-sec-bugs matches the exact owner of the
invoke instruction, so a class and the interface it implements are separate owners.

The index rule, in one place (`sink_slots`): find-sec-bugs counts operand stack slots from
the top, 0 being the last slot of the last argument, and a long or double takes two. A
line lists the slot of every String, Object and Object[] parameter that is a message, a
format or a format argument, and nothing else: never a Throwable, a Logger$Level, the
loggerFqcn String or a primitive, which cannot carry CR or LF and fire as noise on a
constant format. The loggerFqcn String is a String directly followed by a Logger$Level,
or, in the methods not ending in f or v, a String directly followed by an Object (the
(String, Object, Throwable)-shaped overloads); in the f and v methods a String is the
format.

Generate (needs a JDK):  jboss_logging_sinks.py CLASSPATH CLASS... > the file
  runs `javap -s -public` over each CLASS (dotted name) with a timeout and prints the
  sorted sink lines.
Check (offline):  jboss_logging_sinks.py --check FILE
  validates every line against the same rule; one ERROR line per bad line, exit 1.
"""

import re
import subprocess
import sys

OWNERS = {
    "org/jboss/logging/Logger",
    "org/jboss/logging/BasicLogger",
    "io/quarkus/logging/Log",
}
LEVELS = ("trace", "debug", "info", "warn", "error", "fatal")
NAMES = {level + suffix for level in LEVELS for suffix in ("", "f", "v")} | {"log", "logf", "logv"}
LEVEL = "Lorg/jboss/logging/Logger$Level;"
THROWABLE = "Ljava/lang/Throwable;"
MESSAGE_TYPES = {"Ljava/lang/String;", "Ljava/lang/Object;", "[Ljava/lang/Object;"}
PARAM = r"\[*(?:L[^;]+;|[BCDFIJSZ])"
LINE = re.compile(rf"([\w/$]+)\.(\w+)\(((?:{PARAM})*)\)V:([\d,]*)")
JAVAP_TIMEOUT_SECONDS = 60


def sink_slots(name: str, params: list[str]) -> list[int]:
    """The sorted sink stack slots of a method with these parameter descriptors."""
    slots, top = [], 0
    for i in range(len(params) - 1, -1, -1):
        param = params[i]
        following = params[i + 1] if i + 1 < len(params) else ""
        fqcn = param == "Ljava/lang/String;" and (
            following == LEVEL or (following == "Ljava/lang/Object;" and name[-1] not in "fv")
        )
        if param in MESSAGE_TYPES:
            slots += [] if fqcn else [top]
        elif param[0] in "L[" and param not in (THROWABLE, LEVEL):
            raise ValueError(f"unknown reference parameter {param}")
        top += 2 if param in "JD" else 1
    return sorted(slots)


def generate(classpath: str, classes: list[str]) -> list[str]:
    """The sorted sink lines of the public log methods of these classes."""
    lines = set()
    for cls in classes:
        javap = subprocess.run(
            ["javap", "-s", "-public", "-cp", classpath, cls],
            capture_output=True, text=True, check=True, timeout=JAVAP_TIMEOUT_SECONDS,
        ).stdout.splitlines()
        for signature, descriptor in zip(javap, javap[1:]):
            name = re.match(r"\s+public .*?(\w+)\(", signature)
            desc = re.fullmatch(r"\s+descriptor: (\(.*\)V)", descriptor)
            if name and desc and name[1] in NAMES:
                params = re.findall(PARAM, desc[1][1:desc[1].index(")")])
                slots = ",".join(map(str, sink_slots(name[1], params)))
                lines.add(f"{cls.replace('.', '/')}.{name[1]}{desc[1]}:{slots}")
    return sorted(lines)


def check(path: str) -> list[str]:
    """One message per bad line of the file."""
    errors, seen = [], None
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle.read().splitlines(), 1):
            match = LINE.fullmatch(line)
            owner, name, params = (match[1], match[2], re.findall(PARAM, match[3])) if match else (None,) * 3
            if not match or owner not in OWNERS or name not in NAMES:
                problem = "not owner.method(descriptor)V:indices of a known owner and log method"
            elif match[4] != ",".join(map(str, sink_slots(name, params))):
                problem = f"indices are not the sink slots {sink_slots(name, params)}"
            elif seen is not None and line <= seen:
                problem = "not sorted or duplicate"
            else:
                problem = ""
            if problem:
                errors.append(f"ERROR {path}:{number}: {problem}: {line}")
            seen = line
    return errors


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--check":
        errors = check(argv[2])
        print("\n".join(errors), file=sys.stderr) if errors else None
        return 1 if errors else 0
    if len(argv) < 3 or argv[1].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    print("\n".join(generate(argv[1], argv[2:])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
