package cases;

import org.jboss.logging.Logger;

class LiteralsOnly {

  private static final Logger LOG = Logger.getLogger(LiteralsOnly.class);

  void run(String id, Exception e) {
    LOG.infof(
        "Import of a long "
            + "message %s", id);
  }
}
