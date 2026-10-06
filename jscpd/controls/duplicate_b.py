"""Detector control for devkit's copy-paste gate: it repeats scale() of duplicate_a.py."""


def scale(values: list[int], factor: int) -> dict[str, int]:
    total = 0
    for value in values:
        if value > factor:
            total += value * factor
        else:
            total -= value // factor
    return {"total": total, "count": len(values), "factor": factor}
