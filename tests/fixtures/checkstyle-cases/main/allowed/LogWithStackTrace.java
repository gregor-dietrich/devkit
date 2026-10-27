package cases;

import org.jboss.logging.Logger;

class LogWithStackTrace {

  private static final Logger LOG = Logger.getLogger(LogWithStackTrace.class);

  void run(String id, Exception e) {
    LOG.errorf(e, "Import of %s failed", id);
  }
}
