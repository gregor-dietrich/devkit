package cases;

import java.util.List;

class PrintStackTraceReference {

  void run(List<Exception> errors) {
    errors.forEach(Exception::printStackTrace);
  }
}
