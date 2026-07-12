import 'dart:convert';

import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/result.dart';
import '../../../reports/domain/entities/report_data.dart';
import '../../../reports/domain/repositories/reports_repository.dart';
import '../../domain/entities/cache_snapshot.dart';
import '../../domain/services/offline_store.dart';
import '../services/cache_policy.dart';
import 'cache_fallback.dart';

final class CachedReportsRepository
    implements ReportsRepository, ReportReadMetadata {
  CachedReportsRepository({
    required this.delegate,
    required this.store,
    required this.accountIdReader,
    required this.warehouseIdReader,
    required this.canViewFinancialMetricsReader,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  final ReportsRepository delegate;
  final OfflineStore store;
  final String? Function() accountIdReader;
  final int? Function() warehouseIdReader;
  final bool Function() canViewFinancialMetricsReader;
  final DateTime Function() now;

  @override
  ReportReadStatus? lastReadStatus;

  @override
  Future<Result<SalesStats>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) => _cached(
    kind: 'sales_stats',
    query: [startDate, endDate],
    loadNetwork: () =>
        delegate.loadSalesStats(startDate: startDate, endDate: endDate),
    encode: _encodeSalesStats,
    decode: _decodeSalesStats,
  );

  @override
  Future<Result<List<SalesTrendPoint>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) => _cached(
    kind: 'sales_trend',
    query: [startDate, endDate],
    loadNetwork: () =>
        delegate.loadSalesTrend(startDate: startDate, endDate: endDate),
    encode: (value) => {
      'items': value
          .map((item) => {'date': item.date, 'amount': item.amount})
          .toList(),
    },
    decode: (value) => (value['items']! as List).map((item) {
      final row = _map(item);
      return SalesTrendPoint(
        date: row['date']! as String,
        amount: (row['amount']! as num).toDouble(),
      );
    }).toList(),
  );

  @override
  Future<Result<List<SalesRankingItem>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) => _cached(
    kind: 'sales_ranking',
    query: [startDate, endDate, metric, limit],
    loadNetwork: () => delegate.loadSalesRanking(
      startDate: startDate,
      endDate: endDate,
      metric: metric,
      limit: limit,
    ),
    encode: (value) => {
      'items': value
          .map(
            (item) => {'product_name': item.productName, 'amount': item.amount},
          )
          .toList(),
    },
    decode: (value) => (value['items']! as List).map((item) {
      final row = _map(item);
      return SalesRankingItem(
        productName: row['product_name']! as String,
        amount: (row['amount']! as num).toDouble(),
      );
    }).toList(),
  );

  @override
  Future<Result<List<InventoryOverviewItem>>> loadInventoryOverview() =>
      _cached(
        kind: 'inventory_overview',
        query: const [],
        loadNetwork: delegate.loadInventoryOverview,
        encode: (value) => {
          'items': value
              .map((item) => {'label': item.label, 'value': item.value})
              .toList(),
        },
        decode: (value) => (value['items']! as List).map((item) {
          final row = _map(item);
          return InventoryOverviewItem(
            label: row['label']! as String,
            value: (row['value']! as num).toDouble(),
          );
        }).toList(),
      );

  @override
  Future<Result<List<InventoryTurnoverItem>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) => _cached(
    kind: 'inventory_turnover',
    query: [startDate, endDate, limit],
    loadNetwork: () => delegate.loadInventoryTurnover(
      startDate: startDate,
      endDate: endDate,
      limit: limit,
    ),
    encode: (value) => {
      'items': value
          .map(
            (item) => {
              'product_name': item.productName,
              'sku': item.sku,
              'sold_quantity': item.soldQuantity,
              'average_stock_quantity': item.averageStockQuantity,
              'turnover_rate': item.turnoverRate,
            },
          )
          .toList(),
    },
    decode: (value) => (value['items']! as List).map((item) {
      final row = _map(item);
      return InventoryTurnoverItem(
        productName: row['product_name']! as String,
        sku: row['sku']! as String,
        soldQuantity: _int(row, 'sold_quantity'),
        averageStockQuantity: (row['average_stock_quantity']! as num)
            .toDouble(),
        turnoverRate: (row['turnover_rate']! as num).toDouble(),
      );
    }).toList(),
  );

  @override
  Future<Result<PageData<SlowMovingInventoryItem>>> loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) => _cached(
    kind: 'slow_moving',
    query: [startDate, endDate, maxSales, page, pageSize],
    loadNetwork: () => delegate.loadSlowMovingInventory(
      startDate: startDate,
      endDate: endDate,
      maxSales: maxSales,
      page: page,
      pageSize: pageSize,
    ),
    encode: _encodeSlowPage,
    decode: _decodeSlowPage,
  );

  Future<Result<T>> _cached<T>({
    required String kind,
    required List<Object> query,
    required Future<Result<T>> Function() loadNetwork,
    required CacheEncoder<T> encode,
    required CacheDecoder<T> decode,
  }) async {
    final account = accountIdReader()?.trim();
    final warehouse = warehouseIdReader();
    if (account == null || account.isEmpty || warehouse == null) {
      return loadNetwork();
    }
    final view = canViewFinancialMetricsReader() ? 'financial' : 'basic';
    final result = await cacheNetworkFirst(
      store: store,
      key: CacheKey(
        accountId: account,
        warehouseId: warehouse,
        namespace: 'reports.$view.$kind',
        entityKey: jsonEncode(query.map(_queryValue).toList()),
      ),
      policy: CachePolicy.reports,
      now: now,
      loadNetwork: loadNetwork,
      encode: encode,
      decode: decode,
    );
    return switch (result) {
      Success<CacheSnapshot<T>>(data: final snapshot) => () {
        lastReadStatus = ReportReadStatus(
          source: snapshot.source == DataSourceKind.cache
              ? ReportDataSource.cache
              : ReportDataSource.network,
          fetchedAt: snapshot.fetchedAt,
          expiresAt: snapshot.expiresAt,
        );
        return Success<T>(snapshot.value);
      }(),
      FailureResult<CacheSnapshot<T>>(failure: final failure) =>
        FailureResult<T>(failure),
    };
  }
}

Object _queryValue(Object value) =>
    value is DateTime ? value.toUtc().toIso8601String() : value;
Map<String, Object?> _encodeSalesStats(SalesStats value) => {
  'revenue': value.revenue,
  'order_count': value.orderCount,
  'sku_count': value.skuCount,
  'quantity': value.quantity,
  if (value.costAmount != null) 'cost_amount': value.costAmount,
  if (value.grossProfit != null) 'gross_profit': value.grossProfit,
};
SalesStats _decodeSalesStats(Map<String, Object?> value) => SalesStats(
  revenue: (value['revenue']! as num).toDouble(),
  orderCount: _int(value, 'order_count'),
  skuCount: _int(value, 'sku_count'),
  quantity: _int(value, 'quantity'),
  costAmount: (value['cost_amount'] as num?)?.toDouble(),
  grossProfit: (value['gross_profit'] as num?)?.toDouble(),
);
Map<String, Object?> _encodeSlowPage(PageData<SlowMovingInventoryItem> value) =>
    {
      'items': value.items
          .map(
            (item) => {
              'product_name': item.productName,
              'sku': item.sku,
              'stock_quantity': item.stockQuantity,
              'sales_quantity': item.salesQuantity,
              'last_sale_at': item.lastSaleAt,
            },
          )
          .toList(),
      'total': value.total,
      'page': value.page,
      'page_size': value.pageSize,
    };
PageData<SlowMovingInventoryItem> _decodeSlowPage(Map<String, Object?> value) =>
    PageData(
      items: (value['items']! as List).map((item) {
        final row = _map(item);
        return SlowMovingInventoryItem(
          productName: row['product_name']! as String,
          sku: row['sku']! as String,
          stockQuantity: _int(row, 'stock_quantity'),
          salesQuantity: _int(row, 'sales_quantity'),
          lastSaleAt: row['last_sale_at'] as String?,
        );
      }).toList(),
      total: _int(value, 'total'),
      page: _int(value, 'page'),
      pageSize: _int(value, 'page_size'),
    );
Map<String, Object?> _map(Object? value) =>
    Map<String, Object?>.from(value! as Map);
int _int(Map<String, Object?> value, String key) =>
    (value[key]! as num).toInt();
