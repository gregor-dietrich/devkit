"""Detector control for devkit's copy-paste gate: no other control repeats label()."""


def label(name: str) -> str:
    return name.strip().title() or "unnamed"
