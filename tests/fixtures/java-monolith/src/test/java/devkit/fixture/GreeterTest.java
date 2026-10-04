package devkit.fixture;

import static org.junit.jupiter.api.Assertions.assertEquals;

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
}
