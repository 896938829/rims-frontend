import 'package:dio/dio.dart';

import '../../../../core/network/api_client.dart';
import '../../../../core/network/api_endpoints.dart';
import '../../../../core/network/api_envelope.dart';
import '../../../../core/result/failure.dart';
import '../../../../core/result/result.dart';
import '../models/report_models.dart';

abstract interface class ReportsRemoteDataSource {
  Future<Result<List<SalesTrendPointModel>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<SalesRankingItemModel>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
  });

  Future<Result<List<InventoryOverviewItemModel>>> loadInventoryOverview();
}

final class ApiReportsRemoteDataSource implements ReportsRemoteDataSource {
  const ApiReportsRemoteDataSource(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<Result<List<SalesTrendPointModel>>> loadSalesTrend({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.salesTrend,
      queryParameters: _dateRangeQuery(startDate, endDate),
    );

    return _mapEnvelope(result, _parseTrendPoints);
  }

  @override
  Future<Result<List<SalesRankingItemModel>>> loadSalesRanking({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final result = await _apiClient.get<dynamic>(
      ApiEndpoints.salesRanking,
      queryParameters: _dateRangeQuery(startDate, endDate),
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

        return Success<T>(convert(envelope.data));
      },
      failure: FailureResult<T>.new,
    );
  }

  List<SalesTrendPointModel> _parseTrendPoints(Object? data) {
    return _readList(data)
        .whereType<Map>()
        .map((json) => SalesTrendPointModel.fromJson(json))
        .toList(growable: false);
  }

  List<SalesRankingItemModel> _parseRankingItems(Object? data) {
    return _readList(data)
        .whereType<Map>()
        .map((json) => SalesRankingItemModel.fromJson(json))
        .toList(growable: false);
  }

  List<InventoryOverviewItemModel> _parseOverviewItems(Object? data) {
    final list = _readList(data);
    if (list.isNotEmpty) {
      return list
          .whereType<Map>()
          .map((json) => InventoryOverviewItemModel.fromJson(json))
          .toList(growable: false);
    }

    if (data is Map) {
      return overviewItemsFromSummary(data);
    }

    return const [];
  }

  List<dynamic> _readList(Object? data) {
    return switch (data) {
      {'points': final List<dynamic> list} => list,
      {'trend': final List<dynamic> list} => list,
      {'rankings': final List<dynamic> list} => list,
      {'buckets': final List<dynamic> list} => list,
      {'list': final List<dynamic> list} => list,
      {'items': final List<dynamic> list} => list,
      {'records': final List<dynamic> list} => list,
      final List<dynamic> list => list,
      _ => const <dynamic>[],
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
