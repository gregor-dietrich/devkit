package cases;

import org.jboss.logging.Logger;

class ArithmeticArgument {

  private static final Logger LOG = Logger.getLogger(ArithmeticArgument.class);

  void run(String id, Exception e) {
    LOG.infof("Length %s", id.length() + 1);
  }
}
