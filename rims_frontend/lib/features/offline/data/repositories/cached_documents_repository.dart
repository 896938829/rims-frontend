import 'dart:convert';

import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/result.dart';
import '../../../documents/domain/entities/document_data.dart';
import '../../../documents/domain/repositories/documents_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../services/cache_policy.dart';
import 'cache_fallback.dart';

final class CachedDocumentsRepository
    implements
        DocumentsRepository,
        DocumentDetailsRepository,
        DocumentReadMetadata {
  CachedDocumentsRepository({
    required this.delegate,
    required this.store,
    required this.accountIdReader,
    required this.warehouseIdReader,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final DocumentsRepository delegate;
  final OfflineStore store;
  final String? Function() accountIdReader;
  final int? Function() warehouseIdReader;
  final DateTime Function() now;

  @override
  DocumentReadStatus? lastReadStatus;

  @override
  Future<Result<PageData<DocumentRecord>>> listRecentDocuments({
    int? docType,
    int page = 1,
  }) {
    return _cached(
      namespace: 'documents.recent',
      entityKey: jsonEncode([docType, page]),
      policy: CachePolicy.recentDocuments,
      loadNetwork: () =>
          delegate.listRecentDocuments(docType: docType, page: page),
      encode: _encodePage,
      decode: _decodePage,
    );
  }

  @override
  Future<Result<DocumentDetail>> getDocument(int id) {
    return _cached(
      namespace: 'documents.detail',
      entityKey: '$id',
      policy: CachePolicy.recentDocuments,
      loadNetwork: () => getDocumentDetails(delegate, id),
      encode: _encodeDetail,
      decode: _decodeDetail,
    );
  }

  @override
  Future<Result<PageData<TransactionRecord>>> listTransactions({
    String keyword = '',
    int page = 1,
  }) => delegate.listTransactions(keyword: keyword, page: page);

  @override
  Future<Result<DocumentRecord>> createDocument(
    CreateDocumentRequest request,
  ) async {
    final result = await delegate.createDocument(request);
    await _invalidateOnSuccess(result);
    return result;
  }

  @override
  Future<Result<void>> completeDocument(int id) async {
    final result = await delegate.completeDocument(id);
    await _invalidateOnSuccess(result);
    return result;
  }

  @override
  Future<Result<void>> confirmDocument(int id) async {
    final result = await delegate.confirmDocument(id);
    await _invalidateOnSuccess(result);
    return result;
  }

  @override
  Future<Result<void>> settleDocument(int id) async {
    final result = await delegate.settleDocument(id);
    await _invalidateOnSuccess(result);
    return result;
  }

  Future<Result<T>> _cached<T>({
    required String namespace,
    required String entityKey,
    required CachePolicy policy,
    required Future<Result<T>> Function() loadNetwork,
    required CacheEncoder<T> encode,
    required CacheDecoder<T> decode,
  }) async {
    final scope = _scope();
    if (scope == null) return loadNetwork();
    final result = await cacheNetworkFirst(
      store: store,
      key: CacheKey(
        accountId: scope.accountId,
        warehouseId: scope.warehouseId,
        namespace: namespace,
        entityKey: entityKey,
      ),
      policy: policy,
      now: now,
      loadNetwork: loadNetwork,
      encode: encode,
      decode: decode,
    );
    return switch (result) {
      Success<CacheSnapshot<T>>(data: final snapshot) => () {
        lastReadStatus = DocumentReadStatus(
          source: snapshot.source == DataSourceKind.cache
              ? DocumentDataSource.cache
              : DocumentDataSource.network,
          fetchedAt: snapshot.fetchedAt,
          expiresAt: snapshot.expiresAt,
        );
        return Success<T>(snapshot.value);
      }(),
      FailureResult<CacheSnapshot<T>>(failure: final failure) =>
        FailureResult<T>(failure),
    };
  }

  Future<void> _invalidateOnSuccess<T>(Result<T> result) async {
    if (!result.isSuccess) return;
    final scope = _scope();
    if (scope != null) {
      await store.invalidateWarehouseCache(
        accountId: scope.accountId,
        warehouseId: scope.warehouseId,
      );
    }
  }

  ({String accountId, int warehouseId})? _scope() {
    final account = accountIdReader()?.trim();
    final warehouse = warehouseIdReader();
    if (account == null || account.isEmpty || warehouse == null) return null;
    return (accountId: account, warehouseId: warehouse);
  }
}

Map<String, Object?> _encodePage(PageData<DocumentRecord> value) => {
  'items': value.items.map(_encodeRecord).toList(),
  'total': value.total,
  'page': value.page,
  'page_size': value.pageSize,
};
PageData<DocumentRecord> _decodePage(Map<String, Object?> value) => PageData(
  items: (value['items']! as List)
      .map((item) => _decodeRecord(_map(item)))
      .toList(),
  total: _int(value, 'total'),
  page: _int(value, 'page'),
  pageSize: _int(value, 'page_size'),
);
Map<String, Object?> _encodeRecord(DocumentRecord value) => {
  'id': value.id,
  'doc_type': value.docType,
  'title': value.title,
  'number': value.number,
  'status': value.status,
  'product_name': value.productName,
  'quantity': value.quantity,
  'remark': value.remark,
  'created_at': value.createdAt,
};
DocumentRecord _decodeRecord(Map<String, Object?> value) => DocumentRecord(
  id: _int(value, 'id'),
  docType: _int(value, 'doc_type'),
  title: value['title']! as String,
  number: value['number']! as String,
  status: value['status']! as String,
  productName: value['product_name']! as String,
  quantity: _int(value, 'quantity'),
  remark: value['remark']! as String,
  createdAt: value['created_at']! as String,
);
Map<String, Object?> _encodeDetail(DocumentDetail value) => {
  'record': _encodeRecord(value.record),
  'lines': value.lines.map(_encodeLine).toList(),
};
DocumentDetail _decodeDetail(Map<String, Object?> value) => DocumentDetail(
  record: _decodeRecord(_map(value['record'])),
  lines: (value['lines']! as List)
      .map((line) => _decodeLine(_map(line)))
      .toList(),
);
Map<String, Object?> _encodeLine(DocumentLine value) => {
  'id': value.id,
  'product_id': value.productId,
  'non_standard_inventory_id': value.nonStandardInventoryId,
  'product_code': value.productCode,
  'product_name': value.productName,
  'quantity': value.quantity,
  'unit': value.unit,
  'cost_price': value.costPrice,
  'retail_price': value.retailPrice,
  'system_quantity': value.systemQuantity,
  'actual_quantity': value.actualQuantity,
  'difference_quantity': value.differenceQuantity,
  'remark': value.remark,
};
DocumentLine _decodeLine(Map<String, Object?> value) => DocumentLine(
  id: _int(value, 'id'),
  productId: _int(value, 'product_id'),
  nonStandardInventoryId: _int(value, 'non_standard_inventory_id'),
  productCode: value['product_code']! as String,
  productName: value['product_name']! as String,
  quantity: _int(value, 'quantity'),
  unit: value['unit']! as String,
  costPrice: (value['cost_price']! as num).toDouble(),
  retailPrice: (value['retail_price']! as num).toDouble(),
  systemQuantity: _int(value, 'system_quantity'),
  actualQuantity: _int(value, 'actual_quantity'),
  differenceQuantity: _int(value, 'difference_quantity'),
  remark: value['remark']! as String,
);
Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);
int _int(Map<String, Object?> value, String key) =>
    (value[key]! as num).toInt();
