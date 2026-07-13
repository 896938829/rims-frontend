import 'dart:convert';

import 'package:crypto/crypto.dart';

String canonicalOfflineContentDigest(Object? value) {
  return sha256.convert(utf8.encode(_canonicalEncode(value))).toString();
}

String _canonicalEncode(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return jsonEncode(value);
  }
  if (value is List) {
    return '[${value.map(_canonicalEncode).join(',')}]';
  }
  if (value is Map) {
    final entries =
        value.entries
            .map((entry) => MapEntry(entry.key.toString(), entry.value))
            .toList()
          ..sort((left, right) => left.key.compareTo(right.key));
    return '{${entries.map((entry) => '${jsonEncode(entry.key)}:'
        '${_canonicalEncode(entry.value)}').join(',')}}';
  }
  throw ArgumentError.value(value, 'value', 'Unsupported offline payload');
}
