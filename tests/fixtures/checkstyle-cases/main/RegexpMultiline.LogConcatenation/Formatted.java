package cases;

import org.jboss.logging.Logger;

class Formatted {

  private static final Logger LOG = Logger.getLogger(Formatted.class);

  void run(String id, Exception e) {
    LOG.info("Import of %s".formatted(id));
  }
}
