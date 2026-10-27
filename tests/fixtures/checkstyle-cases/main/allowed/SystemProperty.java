package cases;

class SystemProperty {

  void run(String id) {
    String dir = System.getProperty("java.io.tmpdir");
    dir.length();
  }
}
