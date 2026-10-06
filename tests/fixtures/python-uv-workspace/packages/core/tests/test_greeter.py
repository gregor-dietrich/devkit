import pytest

from devkit_core.greeter import greet


def test_greets_by_name() -> None:
    assert greet("world") == "Hello, world"


def test_rejects_a_blank_name() -> None:
    with pytest.raises(ValueError):
        greet(" ")
