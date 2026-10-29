package devkit.fixture.api;

import static org.junit.jupiter.api.Assertions.assertEquals;

import jakarta.inject.Inject;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

@QuarkusTest
class GreetingTest {

    @Inject
    Greeting greeting;

    @Test
    void greetsTheWorldWhenTheNameIsBlank() {
        assertEquals("Hello, world", greeting.of(" "));
    }

    @Test
    void greetsByName() {
        assertEquals("Hello, Ada", greeting.of("Ada"));
    }
}
