import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/pagination/page_data.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/entities/non_standard_inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/inventory/presentation/pages/inventory_page.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';

void main() {
  testWidgets('load-more control requests next page and exposes retry', (
    tester,
  ) async {
    final repository = _PageRepository([
      Success(_page([_item], total: 21)),
      const FailureResult<PageData<InventoryItem>>(
        NetworkFailure(message: 'next page failed'),
      ),
    ]);
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('inventory-load-more-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('inventory-load-more-button')));
    await tester.pumpAndSettle();

    expect(repository.requestedPages, [1, 2]);
    expect(find.byKey(const Key('inventory-load-more-retry')), findsOneWidget);
    expect(find.byKey(const Key('inventory-page-end')), findsNothing);
  });

  testWidgets('end indicator appears after the final non-empty page', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _PageRepository([
        Success(_page([_item])),
      ]),
    );
    await viewModel.load();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    expect(find.byKey(const Key('inventory-page-end')), findsOneWidget);
    expect(find.byKey(const Key('inventory-load-more-button')), findsNothing);
  });

  testWidgets('paging controls stay hidden without a successful first row', (
    tester,
  ) async {
    final emptyViewModel = InventoryViewModel(
      repository: _PageRepository([Success(_page([]))]),
    );
    await emptyViewModel.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: emptyViewModel)),
      ),
    );

    expect(find.byKey(const Key('inventory-load-more-button')), findsNothing);
    expect(find.byKey(const Key('inventory-page-end')), findsNothing);

    final failedViewModel = InventoryViewModel(
      repository: _PageRepository([
        const FailureResult<PageData<InventoryItem>>(
          NetworkFailure(message: 'first page failed'),
        ),
      ]),
    );
    await failedViewModel.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: failedViewModel)),
      ),
    );

    expect(find.byKey(const Key('inventory-load-more-button')), findsNothing);
    expect(find.byKey(const Key('inventory-page-end')), findsNothing);
  });

  testWidgets('local tab with no current matches can still load later pages', (
    tester,
  ) async {
    final viewModel = InventoryViewModel(
      repository: _PageRepository([
        Success(_page([_item], total: 21)),
      ]),
    );
    await viewModel.load();
    viewModel.selectTab('低库存');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InventoryPage(viewModel: viewModel)),
      ),
    );

    expect(find.text('没有匹配的库存商品'), findsOneWidget);
    expect(find.byKey(const Key('inventory-load-more-button')), findsOneWidget);
  });

  testWidgets('scan icon opens scanner result as authoritative detail', (
    tester,
  ) async {
    final repository = _PageRepository([Success(_page([]))]);
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();
    var launches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryPage(
            viewModel: viewModel,
            onScanRequested: (_) async {
              launches++;
              return _item;
            },
          ),
        ),
      ),
    );

    final scanButton = find.byKey(const Key('inventory-scan-button'));
    await tester.ensureVisible(scanButton);
    await tester.tap(scanButton);
    await tester.pumpAndSettle();

    expect(launches, 1);
    expect(find.text('库存详情'), findsOneWidget);
    expect(find.text('M9-PAGE-0001'), findsWidgets);
  });

  testWidgets('keyboard wedge barcode uses the same authoritative lookup', (
    tester,
  ) async {
    final repository = _PageRepository([Success(_page([]))]);
    final viewModel = InventoryViewModel(repository: repository);
    await viewModel.load();
    final barcodes = StreamController<String>.broadcast();
    addTearDown(barcodes.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InventoryPage(
            viewModel: viewModel,
            barcodeInputs: barcodes.stream,
          ),
        ),
      ),
    );

    barcodes.add('M10-ACTIVE-001');
    await tester.pumpAndSettle();

    expect(repository.barcodeLookups, ['M10-ACTIVE-001']);
    expect(find.text('库存详情'), findsOneWidget);
  });
}

PageData<InventoryItem> _page(
  List<InventoryItem> items, {
  int? total,
  int page = 1,
}) {
  return PageData(
    items: items,
    total: total ?? items.length,
    page: page,
    pageSize: 20,
  );
}

const _item = InventoryItem(
  id: 1,
  productId: 10,
  productName: 'M9 product',
  sku: 'M9-PAGE-0001',
  availableQuantity: 10,
  stockQuantity: 10,
  statusLabel: '标准',
  imageUrl: '',
);

final class _PageRepository implements InventoryRepository {
  _PageRepository(this._results);

  final List<Result<PageData<InventoryItem>>> _results;
  final List<int> requestedPages = [];
  final List<String> barcodeLookups = [];
  int _index = 0;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    requestedPages.add(page);
    final result = _results[_index];
    _index += 1;
    return result;
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({
    int page = 1,
  }) async {
    return Success(_page([]));
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    barcodeLookups.add(barcode);
    return const Success(_item);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    return Success(
      PageData(
        items: const <NonStandardInventoryItem>[],
        total: 0,
        page: 1,
        pageSize: 20,
      ),
    );
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    return const Success(_item);
  }
}
