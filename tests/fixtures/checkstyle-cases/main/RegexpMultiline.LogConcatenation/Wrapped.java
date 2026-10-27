package cases;

import org.jboss.logging.Logger;

class Wrapped {

  private static final Logger LOG = Logger.getLogger(Wrapped.class);

  void run(String id, Exception e) {
    LOG.infof(
        "Import of "
            + id);
  }
}
