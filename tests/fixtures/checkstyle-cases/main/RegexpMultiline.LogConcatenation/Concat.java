package cases;

import org.jboss.logging.Logger;

class Concat {

  private static final Logger LOG = Logger.getLogger(Concat.class);

  void run(String id, Exception e) {
    LOG.info("Import of ".concat(id));
  }
}
