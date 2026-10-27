package cases;

import java.text.MessageFormat;
import org.jboss.logging.Logger;

class MessageFormatFormat {

  private static final Logger LOG = Logger.getLogger(MessageFormatFormat.class);

  void run(String id, Exception e) {
    LOG.info(MessageFormat.format("Import of {0}", id));
  }
}
