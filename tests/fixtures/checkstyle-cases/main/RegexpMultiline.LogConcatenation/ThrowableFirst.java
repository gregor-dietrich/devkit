package cases;

import org.jboss.logging.Logger;

class ThrowableFirst {

  private static final Logger LOG = Logger.getLogger(ThrowableFirst.class);

  void run(String id, Exception e) {
    LOG.errorf(e, "Import of " + id);
  }
}
