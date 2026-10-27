package cases;

import org.jboss.logging.Logger;
import org.jboss.logging.Logger.Level;

class LevelArgumentF {

  private static final Logger LOG = Logger.getLogger(LevelArgumentF.class);

  void run(String id, Exception e) {
    LOG.logf(Level.WARN, "Import of " + id);
  }
}
