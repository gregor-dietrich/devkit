package devkit.fixture.ui;

import com.vaadin.flow.component.html.Div;

/** A Vaadin component whose constructor builds its content. */
public class Banner extends Div {

    /** Creates a banner reading "hello". */
    public Banner() {
        add(new Div("hello"));
    }
}
