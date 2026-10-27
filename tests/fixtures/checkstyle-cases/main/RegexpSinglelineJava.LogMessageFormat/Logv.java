package cases;

import org.jboss.logging.Logger;
import org.jboss.logging.Logger.Level;

class Logv {

  private static final Logger LOG = Logger.getLogger(Logv.class);

  void run(String id, Exception e) {
    LOG.logv(Level.INFO, "Import of {0}", id);
  }
}
