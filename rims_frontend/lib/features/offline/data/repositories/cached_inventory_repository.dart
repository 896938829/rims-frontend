import 'dart:convert';

import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/result.dart';
import '../../../inventory/domain/entities/inventory_item.dart';
import '../../../inventory/domain/entities/non_standard_inventory_item.dart';
import '../../../inventory/domain/repositories/inventory_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../services/cache_policy.dart';
import 'cache_fallback.dart';

typedef AccountIdReader = String? Function();
typedef CurrentWarehouseIdReader = int? Function();

final class CachedInventoryRepository
    implements InventoryRepository, InventoryReadMetadata {
  CachedInventoryRepository({
    required this.delegate,
    required this.store,
    required this.accountIdReader,
    required this.warehouseIdReader,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final InventoryRepository delegate;
  final OfflineStore store;
  final AccountIdReader accountIdReader;
  final CurrentWarehouseIdReader warehouseIdReader;
  final DateTime Function() now;

  @override
  InventoryReadStatus? lastReadStatus;

  @override
  Future<Result<PageData<InventoryItem>>> listInventory({
    String keyword = '',
    int page = 1,
  }) {
    final normalizedKeyword = keyword.trim();
    return _inventoryPage(
      namespace: 'inventory.page',
      entityKey: _pageKey(normalizedKeyword, page),
      nextEntityKey: _pageKey(normalizedKeyword, page + 1),
      loadNetwork: () =>
          delegate.listInventory(keyword: normalizedKeyword, page: page),
    );
  }

  @override
  Future<Result<PageData<InventoryItem>>> listInventoryAlerts({int page = 1}) {
    return _inventoryPage(
      namespace: 'inventory.alerts',
      entityKey: _pageKey('', page),
      nextEntityKey: _pageKey('', page + 1),
      loadNetwork: () => delegate.listInventoryAlerts(page: page),
    );
  }

  Future<Result<PageData<InventoryItem>>> _inventoryPage({
    required String namespace,
    required String entityKey,
    required String nextEntityKey,
    required Future<Result<PageData<InventoryItem>>> Function() loadNetwork,
  }) async {
    final scope = _scope();
    if (scope == null) return loadNetwork();
    final key = CacheKey(
      accountId: scope.accountId,
      warehouseId: scope.warehouseId,
      namespace: namespace,
      entityKey: entityKey,
    );
    final result = await cacheNetworkFirst<PageData<InventoryItem>>(
      store: store,
      key: key,
      policy: CachePolicy.references,
      now: now,
      loadNetwork: loadNetwork,
      encode: _encodeInventoryPage,
      decode: _decodeInventoryPage,
    );
    return _unwrapPageSnapshot(
      result,
      nextKey: CacheKey(
        accountId: scope.accountId,
        warehouseId: scope.warehouseId,
        namespace: namespace,
        entityKey: nextEntityKey,
      ),
    );
  }

  Future<Result<PageData<InventoryItem>>> _unwrapPageSnapshot(
    Result<CacheSnapshot<PageData<InventoryItem>>> result, {
    required CacheKey nextKey,
  }) async {
    return switch (result) {
      FailureResult<CacheSnapshot<PageData<InventoryItem>>>(
        failure: final failure,
      ) =>
        FailureResult(failure),
      Success<CacheSnapshot<PageData<InventoryItem>>>(data: final snapshot) =>
        Success(await _pageWithGapBoundary(snapshot, nextKey)),
    };
  }

  Future<PageData<InventoryItem>> _pageWithGapBoundary(
    CacheSnapshot<PageData<InventoryItem>> snapshot,
    CacheKey nextKey,
  ) async {
    _recordStatus(snapshot);
    final page = snapshot.value;
    if (snapshot.source == DataSourceKind.network || !page.hasNextPage) {
      return page;
    }
    final next = await store.readCache(
      nextKey,
      schemaVersion: CachePolicy.references.schemaVersion,
    );
    if (next != null) return page;
    return PageData(
      items: page.items,
      total: page.page * page.pageSize,
      page: page.page,
      pageSize: page.pageSize,
    );
  }

  @override
  Future<Result<InventoryItem>> findProductByBarcode(String barcode) async {
    final normalized = barcode.trim();
    final scope = _scope();
    if (scope == null) return delegate.findProductByBarcode(normalized);
    final result = await cacheNetworkFirst<InventoryItem>(
      store: store,
      key: CacheKey(
        accountId: scope.accountId,
        warehouseId: scope.warehouseId,
        namespace: 'inventory.barcode',
        entityKey: normalized,
      ),
      policy: CachePolicy.references,
      now: now,
      loadNetwork: () => delegate.findProductByBarcode(normalized),
      encode: _encodeInventoryIdentity,
      decode: _decodeInventoryIdentity,
    );
    return _unwrapSnapshot(result);
  }

  @override
  Future<Result<PageData<NonStandardInventoryItem>>> listNonStandardInventory({
    int page = 1,
  }) async {
    final scope = _scope();
    if (scope == null) return delegate.listNonStandardInventory(page: page);
    final result = await cacheNetworkFirst<PageData<NonStandardInventoryItem>>(
      store: store,
      key: CacheKey(
        accountId: scope.accountId,
        warehouseId: scope.warehouseId,
        namespace: 'inventory.non_standard',
        entityKey: _pageKey('', page),
      ),
      policy: CachePolicy.references,
      now: now,
      loadNetwork: () => delegate.listNonStandardInventory(page: page),
      encode: _encodeNonStandardPage,
      decode: _decodeNonStandardPage,
    );
    return _unwrapSnapshot(result);
  }

  @override
  Future<Result<InventoryItem>> updateInventorySettings({
    required int inventoryId,
    int? alertThreshold,
    int? status,
  }) async {
    final result = await delegate.updateInventorySettings(
      inventoryId: inventoryId,
      alertThreshold: alertThreshold,
      status: status,
    );
    if (result.isSuccess) {
      final scope = _scope();
      if (scope != null) {
        await store.invalidateWarehouseCache(
          accountId: scope.accountId,
          warehouseId: scope.warehouseId,
        );
      }
    }
    return result;
  }

  Future<Result<T>> _unwrapSnapshot<T>(Result<CacheSnapshot<T>> result) async {
    return switch (result) {
      Success<CacheSnapshot<T>>(data: final snapshot) => () {
        _recordStatus(snapshot);
        return Success<T>(snapshot.value);
      }(),
      FailureResult<CacheSnapshot<T>>(failure: final failure) =>
        FailureResult<T>(failure),
    };
  }

  void _recordStatus<T>(CacheSnapshot<T> snapshot) {
    lastReadStatus = InventoryReadStatus(
      source: snapshot.source == DataSourceKind.cache
          ? InventoryDataSource.cache
          : InventoryDataSource.network,
      fetchedAt: snapshot.fetchedAt,
      expiresAt: snapshot.expiresAt,
    );
  }

  ({String accountId, int warehouseId})? _scope() {
    final accountId = accountIdReader()?.trim();
    final warehouseId = warehouseIdReader();
    if (accountId == null || accountId.isEmpty || warehouseId == null) {
      lastReadStatus = null;
      return null;
    }
    return (accountId: accountId, warehouseId: warehouseId);
  }
}

String _pageKey(String keyword, int page) => jsonEncode([keyword, page]);

Map<String, Object?> _encodeInventoryPage(PageData<InventoryItem> page) => {
  'items': page.items.map(_encodeInventoryItem).toList(),
  'total': page.total,
  'page': page.page,
  'page_size': page.pageSize,
};

PageData<InventoryItem> _decodeInventoryPage(Map<String, Object?> payload) =>
    PageData(
      items: (payload['items']! as List)
          .map((value) => _decodeInventoryItem(_map(value)))
          .toList(),
      total: _int(payload, 'total'),
      page: _int(payload, 'page'),
      pageSize: _int(payload, 'page_size'),
    );

Map<String, Object?> _encodeInventoryItem(InventoryItem item) => {
  'id': item.id,
  'product_id': item.productId,
  'product_name': item.productName,
  'sku': item.sku,
  'available_quantity': item.availableQuantity,
  'stock_quantity': item.stockQuantity,
  'status_label': item.statusLabel,
  'image_url': item.imageUrl,
  'alert_threshold': item.alertThreshold,
  'status': item.status,
  'retail_price': item.retailPrice,
};

InventoryItem _decodeInventoryItem(Map<String, Object?> payload) =>
    InventoryItem(
      id: _int(payload, 'id'),
      productId: _int(payload, 'product_id'),
      productName: payload['product_name']! as String,
      sku: payload['sku']! as String,
      availableQuantity: _int(payload, 'available_quantity'),
      stockQuantity: _int(payload, 'stock_quantity'),
      statusLabel: payload['status_label']! as String,
      imageUrl: payload['image_url']! as String,
      alertThreshold: _nullableInt(payload['alert_threshold']),
      status: _nullableInt(payload['status']),
      retailPrice: (payload['retail_price'] as num?)?.toDouble(),
    );

Map<String, Object?> _encodeInventoryIdentity(InventoryItem item) => {
  'id': item.id,
  'product_id': item.productId,
  'product_name': item.productName,
  'sku': item.sku,
  'status_label': item.statusLabel,
  'image_url': item.imageUrl,
  'alert_threshold': item.alertThreshold,
  'status': item.status,
  'retail_price': item.retailPrice,
};

InventoryItem _decodeInventoryIdentity(Map<String, Object?> payload) =>
    InventoryItem(
      id: _int(payload, 'id'),
      productId: _int(payload, 'product_id'),
      productName: payload['product_name']! as String,
      sku: payload['sku']! as String,
      availableQuantity: 0,
      stockQuantity: 0,
      statusLabel: payload['status_label']! as String,
      imageUrl: payload['image_url']! as String,
      alertThreshold: _nullableInt(payload['alert_threshold']),
      status: _nullableInt(payload['status']),
      retailPrice: (payload['retail_price'] as num?)?.toDouble(),
    );

Map<String, Object?> _encodeNonStandardPage(
  PageData<NonStandardInventoryItem> page,
) => {
  'items': page.items
      .map(
        (item) => {
          'id': item.id,
          'temp_label': item.tempLabel,
          'description': item.description,
          'unit': item.unit,
          'quantity': item.quantity,
          'converted_quantity': item.convertedQuantity,
          'remaining_quantity': item.remainingQuantity,
          'status': item.status,
        },
      )
      .toList(),
  'total': page.total,
  'page': page.page,
  'page_size': page.pageSize,
};

PageData<NonStandardInventoryItem> _decodeNonStandardPage(
  Map<String, Object?> payload,
) => PageData(
  items: (payload['items']! as List).map((value) {
    final item = _map(value);
    return NonStandardInventoryItem(
      id: _int(item, 'id'),
      tempLabel: item['temp_label']! as String,
      description: item['description']! as String,
      unit: item['unit']! as String,
      quantity: _int(item, 'quantity'),
      convertedQuantity: _int(item, 'converted_quantity'),
      remainingQuantity: _int(item, 'remaining_quantity'),
      status: _int(item, 'status'),
    );
  }).toList(),
  total: _int(payload, 'total'),
  page: _int(payload, 'page'),
  pageSize: _int(payload, 'page_size'),
);

Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);
int _int(Map<String, Object?> value, String key) =>
    (value[key]! as num).toInt();
int? _nullableInt(Object? value) =>
    value == null ? null : (value as num).toInt();
