import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';
import 'package:rims_frontend/features/inventory/presentation/view_models/inventory_view_model.dart';

void main() {
  test('load sets loading then exposes backend inventory items', () async {
    final pending = Completer<Result<List<InventoryItem>>>();
    final repository = _FakeInventoryRepository(result: pending.future);
    final viewModel = InventoryViewModel(repository: repository);

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);
    expect(repository.lastKeyword, '');

    pending.complete(const Success<List<InventoryItem>>([_standardItem]));
    await loadFuture;

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, isNull);
    expect(viewModel.items, [_standardItem]);
    expect(viewModel.visibleItems, [_standardItem]);
  });

  test('updateQuery reloads inventory with keyword', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(const Success<List<InventoryItem>>([_lowStockItem])),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.updateQuery('water');

    expect(viewModel.query, 'water');
    expect(repository.lastKeyword, 'water');
    expect(viewModel.items, [_lowStockItem]);
  });

  test('failure exposes user-facing error message', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        const FailureResult<List<InventoryItem>>(
          NetworkFailure(message: '网络不可用'),
        ),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.isLoading, isFalse);
    expect(viewModel.errorMessage, '网络不可用');
    expect(viewModel.items, isEmpty);
  });

  test('empty repository result exposes empty state', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(const Success<List<InventoryItem>>([])),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();

    expect(viewModel.isEmpty, isTrue);
    expect(viewModel.visibleItems, isEmpty);
  });

  test('selected tab filters loaded items locally', () async {
    final repository = _FakeInventoryRepository(
      result: Future.value(
        const Success<List<InventoryItem>>([_standardItem, _nonStandardItem]),
      ),
    );
    final viewModel = InventoryViewModel(repository: repository);

    await viewModel.load();
    viewModel.selectTab('非标');

    expect(viewModel.visibleItems, [_nonStandardItem]);

    viewModel.selectTab('标准');

    expect(viewModel.visibleItems, [_standardItem]);
  });
}

const _standardItem = InventoryItem(
  id: 1,
  productId: 10,
  productName: '矿泉水 550ml',
  sku: 'SKU-WA-550',
  availableQuantity: 128,
  stockQuantity: 150,
  statusLabel: '标准',
  imageUrl: '',
);

const _lowStockItem = InventoryItem(
  id: 2,
  productId: 20,
  productName: '低库存商品',
  sku: 'SKU-LOW',
  availableQuantity: 2,
  stockQuantity: 3,
  statusLabel: '低库存',
  imageUrl: '',
);

const _nonStandardItem = InventoryItem(
  id: 3,
  productId: 30,
  productName: '非标样品',
  sku: 'SKU-NS',
  availableQuantity: 8,
  stockQuantity: 8,
  statusLabel: '非标',
  imageUrl: '',
);

final class _FakeInventoryRepository implements InventoryRepository {
  _FakeInventoryRepository({required this.result});

  final Future<Result<List<InventoryItem>>> result;
  String? lastKeyword;

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) {
    lastKeyword = keyword;
    return result;
  }
}
