package cases;

import org.jboss.logging.Logger;
import org.jboss.logging.Logger.Level;

class LevelTemplate {

  private static final Logger LOG = Logger.getLogger(LevelTemplate.class);

  void run(String id, Exception e) {
    LOG.logf(Level.INFO, "Import of %s", id);
  }
}
