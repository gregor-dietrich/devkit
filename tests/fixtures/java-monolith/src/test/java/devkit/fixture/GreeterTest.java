package devkit.fixture;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import java.util.Objects;

import org.junit.jupiter.api.Test;

class GreeterTest {

    private final Greeter greeter = new Greeter();

    @Test
    void greetsByName() {
        assertEquals("Hello, Ada", Objects.requireNonNull(greeter.greet("Ada")));
    }

    @Test
    void greetsTheWorldWhenTheNameIsBlank() {
        assertEquals("Hello, world", greeter.greet(" "));
    }

    @Test
    void parsesNumbersAndRethrowsWhatFails() {
        assertEquals(42, greeter.parse("42"));
        assertThrows(NumberFormatException.class, () -> greeter.parse("x"));
    }
}
