"""Builds greetings."""


def greet(name: str) -> str:
    """Greets name; a blank name is an error."""
    if not name.strip():
        raise ValueError("name must not be blank")
    return f"Hello, {name}"
