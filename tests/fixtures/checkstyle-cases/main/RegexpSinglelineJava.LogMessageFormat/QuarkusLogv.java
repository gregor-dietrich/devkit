package cases;

import io.quarkus.logging.Log;

class QuarkusLogv {

  void run(String x) {
    Log.infov("value {0}", x);
  }
}
