package cases;

import org.jboss.logging.Logger;

class ThrowableTemplate {

  private static final Logger LOG = Logger.getLogger(ThrowableTemplate.class);

  void run(String id, Exception e) {
    LOG.errorf(e, "Import of %s", id);
  }
}
