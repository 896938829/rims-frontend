import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_page_parser.dart';

final class _Item {
  const _Item(this.id);

  factory _Item.fromJson(Map<String, Object?> json) {
    return _Item(json['id']! as int);
  }

  final int id;
}

void main() {
  group('parseApiPage', () {
    test('parses the backend page payload and converts every item', () {
      final page = parseApiPage<_Item>(<String, Object?>{
        'list': <Object?>[
          <String, Object?>{'id': 7},
        ],
        'total': 21,
        'page': 2,
        'pageSize': 20,
      }, _Item.fromJson);

      expect(page.items.single.id, 7);
      expect(page.total, 21);
      expect(page.page, 2);
      expect(page.pageSize, 20);
      expect(page.hasNextPage, isFalse);
    });

    test('accepts integral numeric metadata', () {
      final page = parseApiPage<_Item>(<String, Object?>{
        'list': <Object?>[],
        'total': 21.0,
        'page': 1.0,
        'pageSize': 20.0,
      }, _Item.fromJson);

      expect(page.total, 21);
      expect(page.page, 1);
      expect(page.pageSize, 20);
    });

    test('rejects a missing or non-list item collection', () {
      expect(
        () => parseApiPage<_Item>({
          'total': 0,
          'page': 1,
          'pageSize': 20,
        }, _Item.fromJson),
        throwsFormatException,
      );
      expect(
        () => parseApiPage<_Item>({
          'list': {},
          'total': 0,
          'page': 1,
          'pageSize': 20,
        }, _Item.fromJson),
        throwsFormatException,
      );
    });

    test('rejects missing, non-numeric, and fractional metadata', () {
      for (final payload in <Map<String, Object?>>[
        {'list': [], 'page': 1, 'pageSize': 20},
        {'list': [], 'total': '21', 'page': 1, 'pageSize': 20},
        {'list': [], 'total': 21, 'page': 1.5, 'pageSize': 20},
        {'list': [], 'total': 21, 'page': 1, 'pageSize': double.nan},
      ]) {
        expect(
          () => parseApiPage<_Item>(payload, _Item.fromJson),
          throwsFormatException,
        );
      }
    });

    test('rejects invalid metadata ranges', () {
      for (final payload in <Map<String, Object?>>[
        {'list': [], 'total': -1, 'page': 1, 'pageSize': 20},
        {'list': [], 'total': 0, 'page': 0, 'pageSize': 20},
        {'list': [], 'total': 0, 'page': 1, 'pageSize': 0},
      ]) {
        expect(
          () => parseApiPage<_Item>(payload, _Item.fromJson),
          throwsFormatException,
        );
      }
    });

    test('rejects an item that is not a JSON object', () {
      expect(
        () => parseApiPage<_Item>({
          'list': [7],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        }, _Item.fromJson),
        throwsFormatException,
      );
    });
  });
}
