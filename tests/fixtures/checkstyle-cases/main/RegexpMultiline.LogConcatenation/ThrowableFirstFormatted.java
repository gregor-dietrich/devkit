package cases;

import org.jboss.logging.Logger;

class ThrowableFirstFormatted {

  private static final Logger LOG = Logger.getLogger(ThrowableFirstFormatted.class);

  void run(String id, Exception e) {
    LOG.error(e, "Import of %s".formatted(id));
  }
}
