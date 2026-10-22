import 'package:fixnum/fixnum.dart';

/// SplitMix64: every client replaying the same actions shuffles the same way. The arithmetic is
/// exact 64-bit (fixnum's Int64), so a phone and a browser produce identical sequences.
class SeededRng {
  SeededRng(int seed) : _state = Int64(seed);
  Int64 _state;

  static final _gamma = Int64.parseHex('9E3779B97F4A7C15');
  static final _mix1 = Int64.parseHex('BF58476D1CE4E5B9');
  static final _mix2 = Int64.parseHex('94D049BB133111EB');

  /// The generator's position, as the same text on every platform (for the state digest).
  String get state => _state.toString();

  Int64 _next() {
    _state = _state + _gamma; // wraps in 64 bits
    var z = _state;
    z = (z ^ z.shiftRightUnsigned(30)) * _mix1;
    z = (z ^ z.shiftRightUnsigned(27)) * _mix2;
    return z ^ z.shiftRightUnsigned(31);
  }

  /// A non-negative int below [max].
  int nextInt(int max) => ((_next() & Int64.MAX_VALUE) % Int64(max)).toInt();

  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }
}
