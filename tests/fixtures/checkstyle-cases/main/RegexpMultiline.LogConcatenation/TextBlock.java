package cases;

import org.jboss.logging.Logger;

class TextBlock {

  private static final Logger LOG = Logger.getLogger(TextBlock.class);

  void run(String id, Exception e) {
    LOG.info(
        """
        Import of
        """
            + id);
  }
}
