package devkit.fixture.app;

/** Names the parity of a number. */
public final class Parity {

    /** Returns "even" or "odd" for {@code number}. */
    public String of(int number) {
        return number % 2 == 0 ? "even" : "odd";
    }
}
