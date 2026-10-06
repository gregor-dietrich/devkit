from devkit_app.parity import parity


def test_even() -> None:
    assert parity(2) == "even"


def test_odd() -> None:
    assert parity(3) == "odd"
