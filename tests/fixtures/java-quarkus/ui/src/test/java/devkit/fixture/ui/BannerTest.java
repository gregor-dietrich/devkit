package devkit.fixture.ui;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class BannerTest {

    @Test
    void holdsOneChild() {
        assertEquals(1, new Banner().getChildren().count());
    }
}
