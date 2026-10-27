package cases;

import java.util.List;

class OutMethodReference {

  void run(String id) {
    List.of(id).forEach(System.out::println);
  }
}
