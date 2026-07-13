Map<String, Object?> immutableMapSnapshot(Map<Object?, Object?> source) {
  return Map<String, Object?>.unmodifiable({
    for (final entry in source.entries)
      entry.key.toString(): immutableValueSnapshot(entry.value),
  });
}

Object? immutableValueSnapshot(Object? value) {
  if (value is Map) return immutableMapSnapshot(value);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(immutableValueSnapshot));
  }
  if (value is Set) {
    return Set<Object?>.unmodifiable(value.map(immutableValueSnapshot));
  }
  return value;
}

List<T> immutableListSnapshot<T>(Iterable<T> source) =>
    List<T>.unmodifiable(source);
