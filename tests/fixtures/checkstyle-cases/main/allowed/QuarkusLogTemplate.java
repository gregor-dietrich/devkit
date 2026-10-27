package cases;

import io.quarkus.logging.Log;

class QuarkusLogTemplate {

  void run(String x) {
    Log.infof("value %s", x);
  }
}
