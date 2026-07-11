import 'package:rims_frontend/core/pagination/page_data.dart';

PageData<T> parseApiPage<T>(
  Map<String, Object?> data,
  T Function(Map<String, Object?> json) convert,
) {
  final rawItems = data['list'];
  if (rawItems is! List<Object?>) {
    throw const FormatException('Paged API data.list must be a JSON list.');
  }

  final items = <T>[];
  for (final rawItem in rawItems) {
    if (rawItem is! Map<String, Object?>) {
      throw const FormatException(
        'Every paged API list item must be a JSON object.',
      );
    }
    items.add(convert(rawItem));
  }

  final total = _readInteger(data, 'total');
  final page = _readInteger(data, 'page');
  final pageSize = _readInteger(data, 'pageSize');
  if (total < 0) {
    throw const FormatException('Paged API data.total cannot be negative.');
  }
  if (page < 1) {
    throw const FormatException('Paged API data.page must be at least 1.');
  }
  if (pageSize < 1) {
    throw const FormatException('Paged API data.pageSize must be at least 1.');
  }

  return PageData<T>(
    items: items,
    total: total,
    page: page,
    pageSize: pageSize,
  );
}

int _readInteger(Map<String, Object?> data, String name) {
  final value = data[name];
  if (value is int) {
    return value;
  }
  if (value is num && value.isFinite && value == value.truncate()) {
    return value.toInt();
  }
  throw FormatException('Paged API data.$name must be an integer.');
}
