package devkit.fixture;

import edu.umd.cs.findbugs.annotations.SuppressFBWarnings;

/** Builds greetings. */
public final class Greeter {

    /** Greets {@code name}, or the world when the name is blank. */
    // The locale-less case conversion is the SpotBugs finding the suppression below silences.
    @SuppressWarnings({ "StringCaseLocaleUsage", "PMD.UseLocaleWithCaseConversions" })
    @SuppressFBWarnings(value = "DM_CONVERT_CASE", justification = "Exercises the managed spotbugs-annotations.")
    public String greet(String name) {
        return name.toLowerCase().isBlank() ? "Hello, world" : "Hello, " + name;
    }
}
