"""Names the parity of a number."""


def parity(number: int) -> str:
    """Returns "even" or "odd" for number."""
    return "even" if number % 2 == 0 else "odd"
