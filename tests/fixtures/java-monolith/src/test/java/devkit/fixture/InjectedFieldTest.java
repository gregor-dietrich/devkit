package devkit.fixture;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import io.quarkus.test.InjectMock;
import io.quarkus.test.junit.mockito.InjectSpy;

// No NullAway suppression: the parent treats the injected fields as initialized and an assertion
// as a null check.
class InjectedFieldTest {

    @TempDir
    Path dir;

    // Never injected here, only declared: NullAway must not report them as uninitialized.
    @InjectMock
    Greeter mocked;

    @InjectSpy
    Greeter spied;

    @Test
    void injectedFieldsAreInitialized() {
        assertTrue(Files.isDirectory(dir));
    }

    @Test
    void notNullAssertionRefinesValue() {
        var greeting = Map.of("Ada", "Hello").get("Ada"); // Map.get may return null
        assertNotNull(greeting);
        assertTrue(greeting.startsWith("He"));
    }

    @Test
    void assertThatRefinesValue() {
        var greeting = Map.of("Ada", "Hello").get("Ada"); // Map.get may return null
        assertThat(greeting).isNotNull();
        assertTrue(greeting.startsWith("He"));
    }
}
