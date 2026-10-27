package cases;

import org.jboss.logging.Logger;

class Infov {

  private static final Logger LOG = Logger.getLogger(Infov.class);

  void run(String id, Exception e) {
    LOG.infov("Import of {0}", id);
  }
}
