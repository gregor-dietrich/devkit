package cases;

import java.io.PrintWriter;
import java.io.StringWriter;

class StackToString {

  String render(Exception e) {
    var sw = new StringWriter();
    e.printStackTrace(new PrintWriter(sw));
    return sw.toString();
  }
}
