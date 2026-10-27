package cases;

import org.jboss.logging.Logger;

class StringFormat {

  private static final Logger LOG = Logger.getLogger(StringFormat.class);

  void run(String id, Exception e) {
    LOG.info(String.format("Import of %s", id));
  }
}
