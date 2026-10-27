package cases;

import java.util.List;

class IoPrintlnReference {

  void run(String id) {
    List.of(id).forEach(IO::println);
  }
}
