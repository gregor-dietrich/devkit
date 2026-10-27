package cases;

import java.util.List;
import java.util.function.Function;

class Unnamed {

  record Pair(String first, String second) {}

  int run(List<String> items, Object o) {
    Function<String, Integer> f = _ -> 1;
    int n = f.apply("x");
    for (var _ : items) {
      n++;
    }
    try {
      n++;
    } catch (RuntimeException _) {
      n--;
    }
    var _ = items.size();
    if (o instanceof Pair(String _, String second)) {
      n += second.length();
    }
    return n;
  }
}
