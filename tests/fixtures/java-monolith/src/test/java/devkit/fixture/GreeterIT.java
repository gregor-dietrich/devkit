package devkit.fixture;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

/** Named as failsafe's default patterns expect, which the shared Checkstyle must accept. */
class GreeterIT {

    @Test
    void greetsByName() {
        assertEquals("Hello, Ada", new Greeter().greet("Ada"));
    }

    @Test
    void theParentSwitchesQuarkusJacocoReportOff() {
        assertEquals("false", System.getProperty("quarkus.jacoco.report"));
    }
}
