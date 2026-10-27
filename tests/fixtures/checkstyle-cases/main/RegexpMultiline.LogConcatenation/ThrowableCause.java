package cases;

import org.jboss.logging.Logger;

class ThrowableCause {

  private static final Logger LOG = Logger.getLogger(ThrowableCause.class);

  void run(String id, Exception e) {
    LOG.errorf(e.getCause(), "Import of " + id);
  }
}
