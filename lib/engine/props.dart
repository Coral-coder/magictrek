/// Value equality from a list of properties, so the ability vocabulary and game
/// objects compare by content (needed for sets, lookups and lockstep checks).
mixin Props {
  List<Object?> get props;

  @override
  bool operator ==(Object other) => identical(this, other) || (other is Props && runtimeType == other.runtimeType && deepEquals(props, other.props));

  @override
  int get hashCode => Object.hash(runtimeType, deepHash(props));
}

bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    for (final x in a) {
      if (!b.contains(x)) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

int deepHash(Object? a) {
  if (a is List) return Object.hashAll(a.map(deepHash));
  if (a is Set) return Object.hashAllUnordered(a.map(deepHash));
  if (a is Map) return Object.hashAllUnordered(a.entries.map((e) => Object.hash(deepHash(e.key), deepHash(e.value))));
  return a.hashCode;
}
