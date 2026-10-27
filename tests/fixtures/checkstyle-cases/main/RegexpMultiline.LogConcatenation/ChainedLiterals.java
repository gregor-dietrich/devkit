package cases;

import org.jboss.logging.Logger;

class ChainedLiterals {

  private static final Logger LOG = Logger.getLogger(ChainedLiterals.class);

  void run(String id, Exception e) {
    LOG.infof("Import " + "of " + id);
  }
}
