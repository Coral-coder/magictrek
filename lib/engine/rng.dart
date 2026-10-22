/// SplitMix64 on 64-bit ints: every client replaying the same actions shuffles the same way.
class SeededRng {
  SeededRng(this.state);
  int state;

  int next() {
    state = state + 0x9E3779B97F4A7C15; // wraps in 64-bit Dart ints
    var z = state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// A non-negative int below [max].
  int nextInt(int max) => (next() & 0x7FFFFFFFFFFFFFFF) % max;

  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }
}
