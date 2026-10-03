package devkit.fixture.core;

/** Builds greetings. */
public final class Greeter {

    /** Greets {@code name}, or the world when the name is blank. */
    public String greet(String name) {
        return name.isBlank() ? "Hello, world" : "Hello, " + name;
    }
}
