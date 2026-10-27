package cases;

class PrintStackTraceToSystemOut {

  void run(Exception e) {
    e.printStackTrace(System.out);
  }
}
