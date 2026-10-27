package cases;

import org.jboss.logging.Logger;

class EscapedQuote {

  private static final Logger LOG = Logger.getLogger(EscapedQuote.class);

  void run(String id, Exception e) {
    LOG.infof("Import of \"" + id);
  }
}
