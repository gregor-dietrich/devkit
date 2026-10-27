package cases;

import org.jboss.logging.Logger;

class TestTemplateMessage {

  private static final Logger LOG = Logger.getLogger(TestTemplateMessage.class);

  void run(String id, Exception e) {
    LOG.infof("Import of %s", id);
  }
}
