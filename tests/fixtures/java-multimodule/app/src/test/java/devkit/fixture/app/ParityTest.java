package devkit.fixture.app;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class ParityTest {

    private final Parity parity = new Parity();

    @Test
    void namesAnEvenNumber() {
        assertEquals("even", parity.of(4));
    }

    @Test
    void namesAnOddNumber() {
        assertEquals("odd", parity.of(-3));
    }
}
