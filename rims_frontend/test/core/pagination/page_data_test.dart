import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';

void main() {
  group('PageData', () {
    test('maps items without losing server metadata', () {
      final page = PageData<int>(
        items: [1, 2],
        total: 5,
        page: 2,
        pageSize: 2,
      );

      final mapped = page.map((value) => 'item-$value');

      expect(mapped.items, ['item-1', 'item-2']);
      expect(mapped.total, 5);
      expect(mapped.page, 2);
      expect(mapped.pageSize, 2);
      expect(mapped.hasNextPage, isTrue);
      expect(mapped.nextPage, 3);
    });

    test('exposes an unmodifiable item list', () {
      final source = [1, 2];
      final page = PageData<int>(
        items: source,
        total: 2,
        page: 1,
        pageSize: 20,
      );

      source.add(3);

      expect(page.items, [1, 2]);
      expect(() => page.items.add(4), throwsUnsupportedError);
    });

    test('reports the final and empty page without a next page', () {
      final finalPage = PageData<int>(
        items: [1],
        total: 21,
        page: 2,
        pageSize: 20,
      );
      final emptyPage = PageData<int>(
        items: const [],
        total: 0,
        page: 1,
        pageSize: 20,
      );

      expect(finalPage.hasNextPage, isFalse);
      expect(emptyPage.hasNextPage, isFalse);
    });
  });
}
