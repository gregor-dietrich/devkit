package cases;

import java.util.function.Supplier;

class SystemConsoleReference {

  void run(String id) {
    Supplier<?> console = System::console;
    console.get();
  }
}
