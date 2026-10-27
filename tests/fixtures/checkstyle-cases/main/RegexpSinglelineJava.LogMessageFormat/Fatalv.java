package cases;

import org.jboss.logging.Logger;

class Fatalv {

  private static final Logger LOG = Logger.getLogger(Fatalv.class);

  void run(String id, Exception e) {
    LOG.fatalv("Import of {0}", id);
  }
}
