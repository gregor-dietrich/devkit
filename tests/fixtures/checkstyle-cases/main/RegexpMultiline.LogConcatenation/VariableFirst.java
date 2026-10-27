package cases;

import org.jboss.logging.Logger;

class VariableFirst {

  private static final Logger LOG = Logger.getLogger(VariableFirst.class);

  void run(String id, Exception e) {
    LOG.info(id + " imported");
  }
}
