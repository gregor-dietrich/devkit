package devkit.fixture.core;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class GreeterTest {

    private final Greeter greeter = new Greeter();

    @Test
    void greetsByName() {
        assertEquals("Hello, Ada", greeter.greet("Ada"));
    }

    @Test
    void greetsTheWorldWhenTheNameIsBlank() {
        assertEquals("Hello, world", greeter.greet(" "));
    }
}
