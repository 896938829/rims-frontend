import 'dart:convert';

abstract final class CacheRecordModel {
  static String canonicalJson(Map<String, Object?> payload) {
    return jsonEncode(_canonicalize(payload));
  }

  static Map<String, Object?> decodePayload(String value) {
    return Map<String, Object?>.from(jsonDecode(value) as Map);
  }

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }
}
