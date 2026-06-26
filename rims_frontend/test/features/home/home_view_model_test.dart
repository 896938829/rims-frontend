import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/auth/domain/entities/app_user.dart';
import 'package:rims_frontend/features/auth/domain/entities/warehouse.dart';
import 'package:rims_frontend/features/documents/domain/entities/document_data.dart';
import 'package:rims_frontend/features/documents/domain/repositories/documents_repository.dart';
import 'package:rims_frontend/features/home/presentation/pages/home_page.dart';
import 'package:rims_frontend/features/home/presentation/view_models/home_view_model.dart';
import 'package:rims_frontend/features/inventory/domain/entities/inventory_item.dart';
import 'package:rims_frontend/features/inventory/domain/repositories/inventory_repository.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.clearAllTestValues();
  });

  test('HomeViewModel loads dashboard data from repositories', () async {
    final viewModel = HomeViewModel(
      user: _user,
      warehouse: _warehouse,
      inventoryRepository: const _FakeInventoryRepository(),
      documentsRepository: const _FakeDocumentsRepository(),
    );

    final loadFuture = viewModel.load();

    expect(viewModel.isLoading, isTrue);

    await loadFuture;

    expect(viewModel.warehouseName, '上海仓');
    expect(viewModel.greeting, 'Good morning, 系统管理员');
    expect(viewModel.metrics.map((metric) => metric.value), ['2', '153', '1']);
    expect(viewModel.quickActions, hasLength(4));
    expect(viewModel.warnings.single.label, '低库存');
    expect(viewModel.warnings.single.count, 1);
    expect(viewModel.recentDocuments, [_recentDocument]);
  });

  testWidgets('HomePage does not overflow on narrow mobile viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          user: _user,
          warehouse: _warehouse,
          inventoryRepository: const _FakeInventoryRepository(),
          documentsRepository: const _FakeDocumentsRepository(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}

const _user = AppUser(
  id: 1,
  username: 'admin',
  realName: '系统管理员',
  roleCode: 'admin',
  roleName: '管理员',
);

const _warehouse = Warehouse(id: 1, code: 'SH', name: '上海仓', isDefault: true);

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

const _recentDocument = DocumentRecord(
  id: 1,
  title: '销售出库',
  number: 'SO-20260626-001',
  status: '待提交',
  productName: '矿泉水 550ml',
  quantity: 3,
);

final class _FakeInventoryRepository implements InventoryRepository {
  const _FakeInventoryRepository();

  @override
  Future<Result<List<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) async {
    return const Success<List<InventoryItem>>([_standardItem, _lowStockItem]);
  }
}

final class _FakeDocumentsRepository implements DocumentsRepository {
  const _FakeDocumentsRepository();

  @override
  Future<Result<List<DocumentRecord>>> listRecentDocuments() async {
    return const Success<List<DocumentRecord>>([_recentDocument]);
  }

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    return const Success<DocumentRecord>(_recentDocument);
  }
}
