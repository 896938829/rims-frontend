import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/admin/presentation/widgets/admin_pagination_control.dart';

void main() {
  testWidgets('exposes stable load-more key and invokes callback', (
    tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPaginationControl(
          keyPrefix: 'admin-users-load-more',
          loaded: 20,
          total: 21,
          hasMore: true,
          isLoadingMore: false,
          hasFailure: false,
          onLoadMore: () async => loadMoreCalls += 1,
          onRetry: () async {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('admin-users-load-more')));
    await tester.pump();

    expect(loadMoreCalls, 1);
    expect(find.text('加载更多 (20/21)'), findsOneWidget);
  });

  testWidgets('exposes stable retry key and invokes callback', (tester) async {
    var retryCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AdminPaginationControl(
          keyPrefix: 'admin-products-load-more',
          loaded: 20,
          total: 21,
          hasMore: true,
          isLoadingMore: false,
          hasFailure: true,
          onLoadMore: () async {},
          onRetry: () async => retryCalls += 1,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('admin-products-load-more-retry')));
    await tester.pump();

    expect(retryCalls, 1);
  });

  testWidgets('exposes stable end key', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AdminPaginationControl(
          keyPrefix: 'admin-warehouses-load-more',
          loaded: 2,
          total: 2,
          hasMore: false,
          isLoadingMore: false,
          hasFailure: false,
          onLoadMore: () async {},
          onRetry: () async {},
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin-warehouses-load-more-end')),
      findsOneWidget,
    );
    expect(find.text('已加载全部 2 条'), findsOneWidget);
  });
}
