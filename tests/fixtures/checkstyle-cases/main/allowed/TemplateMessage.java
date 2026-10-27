package cases;

import org.jboss.logging.Logger;

class TemplateMessage {

  private static final Logger LOG = Logger.getLogger(TemplateMessage.class);

  void run(String id, Exception e) {
    LOG.infof("Import of %s", id);
  }
}
