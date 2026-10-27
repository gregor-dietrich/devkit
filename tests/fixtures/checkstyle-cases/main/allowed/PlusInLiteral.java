package cases;

import org.jboss.logging.Logger;

class PlusInLiteral {

  private static final Logger LOG = Logger.getLogger(PlusInLiteral.class);

  void run(String id, Exception e) {
    LOG.infof("1 + 2 = %s", id);
  }
}
