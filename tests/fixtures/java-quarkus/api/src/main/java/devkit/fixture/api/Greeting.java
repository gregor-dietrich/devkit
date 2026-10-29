package devkit.fixture.api;

import jakarta.enterprise.context.ApplicationScoped;

/** Greets by name. Only a {@code @QuarkusTest} exercises it; it is final, so ArC rewrites it. */
@ApplicationScoped
public final class Greeting {

    /** Returns "Hello, world" for a blank {@code name}, otherwise "Hello, " and {@code name}. */
    public String of(String name) {
        return name.isBlank() ? "Hello, world" : "Hello, " + name;
    }
}
