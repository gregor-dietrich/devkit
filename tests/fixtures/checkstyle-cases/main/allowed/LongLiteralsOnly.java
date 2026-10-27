package cases;

import org.jboss.logging.Logger;

class LongLiteralsOnly {

  private static final Logger LOG = Logger.getLogger(LongLiteralsOnly.class);

  void run(String id) {
    LOG.warnf(
        "Line 00 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 01 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 02 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 03 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 04 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 05 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 06 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 07 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 08 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 09 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 10 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 11 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 12 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 13 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 14 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 15 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 16 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 17 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 18 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 19 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 20 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 21 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 22 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 23 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 24 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 25 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 26 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 27 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 28 of a long literal-only message, wrapped by the formatter at its width, "
            + "Line 29 of a long literal-only message, wrapped by the formatter at its width, "
            + "%s",
        id);
  }
}
