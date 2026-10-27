package cases;

import org.jboss.logging.Logger;
import org.jboss.logging.Logger.Level;

class LevelArgument {

  private static final Logger LOG = Logger.getLogger(LevelArgument.class);

  void run(String id, Exception e) {
    LOG.log(Level.INFO, "Import of " + id);
  }
}
