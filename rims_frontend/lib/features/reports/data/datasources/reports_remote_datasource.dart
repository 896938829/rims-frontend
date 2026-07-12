import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/network/api_page_parser.dart';
import '../../../../core/pagination/page_data.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/report_models.dart';

abstract interface class ReportsRemoteDataSource {
  Future<Result<SalesStatsModel>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesTrendPointModel>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesRankingItemModel>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  });

  Future<Result<List<InventoryOverviewItemModel>>> loadInventoryOverview();

  Future<Result<List<InventoryTurnoverItemModel>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  });

  Future<Result<PageData<SlowMovingInventoryItemModel>>>
  loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  });
}

final class ApiReportsRemoteDataSource implements ReportsRemoteDataSource {
  const ApiReportsRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<SalesStatsModel>> loadSalesStats({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.salesStats,
      queryParameters: _dateRangeQuery(startDate, endDate),
    );

    return _mapEnvelope(result, _parseSalesStats);
  }

  @override
  Future<Result<List<SalesTrendPointModel>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.salesTrend,
      queryParameters: {
        ..._dateRangeQuery(startDate, endDate),
        'bucket': 'day',
      },
    );

    return _mapEnvelope(result, _parseTrendPoints);
  }

  @override
  Future<Result<List<SalesRankingItemModel>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
    String metric = 'amount',
    int limit = 5,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.salesRanking,
      queryParameters: {
        ..._dateRangeQuery(startDate, endDate),
        'metric': metric,
        'limit': limit,
      },
    );

    return _mapEnvelope(result, _parseRankingItems);
  }

  @override
  Future<Result<List<InventoryOverviewItemModel>>>
  loadInventoryOverview() async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventoryOverview,
    );

    return _mapEnvelope(result, _parseOverviewItems);
  }

  @override
  Future<Result<List<InventoryTurnoverItemModel>>> loadInventoryTurnover({
    required DateTime startDate,
    required DateTime endDate,
    int limit = 5,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventoryTurnover,
      queryParameters: {..._dateRangeQuery(startDate, endDate), 'limit': limit},
    );

    return _mapEnvelope(result, _parseTurnoverItems);
  }

  @override
  Future<Result<PageData<SlowMovingInventoryItemModel>>>
  loadSlowMovingInventory({
    required DateTime startDate,
    required DateTime endDate,
    int maxSales = 1,
    int page = 1,
    int pageSize = 5,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.inventorySlowMoving,
      queryParameters: {
        ..._dateRangeQuery(startDate, endDate),
        'maxSales': maxSales,
        'page': page,
        'pageSize': pageSize,
      },
    );

    return _mapEnvelope(result, _parseSlowMovingItems);
  }

  Result<T> _mapEnvelope<T>(
    Result<Response<dynamic>> responseResult,
    T Function(Object? data) convert,
  ) {
    return responseResult.when(
      success: (response) {
        final responseData = response.data;
        if (responseData is! Map<dynamic, dynamic>) {
          return FailureResult<T>(
            UnknownFailure(
              message: 'Invalid API response',
              statusCode: response.statusCode,
            ),
          );
        }

        final envelope = ApiEnvelope.fromJson(responseData);
        if (!envelope.isSuccess) {
          return FailureResult<T>(
            UnknownFailure(
              message: envelope.message,
              statusCode: response.statusCode,
              businessCode: envelope.code,
              traceId: envelope.traceId,
            ),
          );
        }

        try {
          return Success<T>(convert(envelope.data));
        } on FormatException catch (error) {
          return FailureResult<T>(
            UnknownFailure(
              message: error.message,
              statusCode: response.statusCode,
              cause: error,
            ),
          );
        }
      },
      failure: FailureResult<T>.new,
    );
  }

  SalesStatsModel _parseSalesStats(Object? data) {
    if (data is Map<dynamic, dynamic>) {
      return SalesStatsModel.fromJson(data);
    }

    throw const FormatException('Invalid sales stats response');
  }

  List<SalesTrendPointModel> _parseTrendPoints(Object? data) {
    return _readRequiredList(data, 'sales trend')
        .mapItems('sales trend')
        .map((json) => SalesTrendPointModel.fromJson(json))
        .toList(growable: false);
  }

  List<SalesRankingItemModel> _parseRankingItems(Object? data) {
    return _readRequiredList(data, 'sales ranking')
        .mapItems('sales ranking')
        .map((json) => SalesRankingItemModel.fromJson(json))
        .toList(growable: false);
  }

  List<InventoryOverviewItemModel> _parseOverviewItems(Object? data) {
    final list = _readListOrNull(data);
    if (list != null) {
      return list
          .mapItems('inventory overview')
          .map((json) => InventoryOverviewItemModel.fromJson(json))
          .toList(growable: false);
    }

    if (data is Map) {
      return overviewItemsFromSummary(data);
    }

    throw const FormatException('Invalid inventory overview response');
  }

  List<InventoryTurnoverItemModel> _parseTurnoverItems(Object? data) {
    return _readRequiredList(data, 'inventory turnover')
        .mapItems('inventory turnover')
        .map((json) => InventoryTurnoverItemModel.fromJson(json))
        .toList(growable: false);
  }

  PageData<SlowMovingInventoryItemModel> _parseSlowMovingItems(Object? data) {
    if (data is! Map<String, Object?>) {
      throw const FormatException('Invalid slow-moving inventory response');
    }
    return parseApiPage(data, SlowMovingInventoryItemModel.fromJson);
  }

  List<dynamic> _readRequiredList(Object? data, String name) {
    final list = _readListOrNull(data);
    if (list != null) {
      return list;
    }

    throw FormatException('Invalid $name response');
  }

  List<dynamic>? _readListOrNull(Object? data) {
    return switch (data) {
      {'points': final List<dynamic> list} => list,
      {'trend': final List<dynamic> list} => list,
      {'rankings': final List<dynamic> list} => list,
      {'buckets': final List<dynamic> list} => list,
      {'list': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      {'rows': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => null,
    };
  }

  Map<String, String> _dateRangeQuery(DateTime startDate, DateTime endDate) {
    return {
      'startDate': _formatDate(startDate),
      'endDate': _formatDate(endDate),
    };
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}

extension on List<dynamic> {
  Iterable<Map<dynamic, dynamic>> mapItems(String name) {
    return map((item) {
      if (item is Map) {
        return Map<dynamic, dynamic>.from(item);
      }

      throw FormatException('Invalid $name response');
    });
  }
}
