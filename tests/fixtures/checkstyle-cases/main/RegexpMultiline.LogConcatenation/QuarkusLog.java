package cases;

import io.quarkus.logging.Log;

class QuarkusLog {

  void run(String x) {
    Log.infof("value " + x);
  }
}
