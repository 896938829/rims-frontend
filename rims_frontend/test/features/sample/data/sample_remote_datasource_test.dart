import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_client.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';
import 'package:rims_frontend/features/sample/data/datasources/sample_remote_datasource.dart';
import 'package:rims_frontend/features/sample/data/models/sample_item_model.dart';

void main() {
  test('getItems parses a valid response list', () async {
    final dataSource = SampleRemoteDataSource(
      _apiClientWithData([
        {'id': '1', 'title': 'Inventory'},
      ]),
    );

    final result = await dataSource.getItems();

    expect(result, isA<Success<List<SampleItemModel>>>());
    expect(
      result.when(
        success: (items) => items.single.title,
        failure: (failure) => failure.message,
      ),
      'Inventory',
    );
  });

  test('getItems returns an empty list when response data is null', () async {
    final dataSource = SampleRemoteDataSource(_apiClientWithData(null));

    final result = await dataSource.getItems();

    expect(result, isA<Success<List<SampleItemModel>>>());
    expect(
      result.when(
        success: (items) => items,
        failure: (_) => const <SampleItemModel>[],
      ),
      isEmpty,
    );
  });

  test('getItems returns ValidationFailure when response is not a list',
      () async {
    final dataSource = SampleRemoteDataSource(
      _apiClientWithData({'id': '1', 'title': 'Inventory'}),
    );

    final result = await dataSource.getItems();

    expect(result, isA<FailureResult<List<SampleItemModel>>>());
    expect(
      result.when(
        success: (_) => null,
        failure: (failure) => failure,
      ),
      isA<ValidationFailure>(),
    );
  });

  test('getItems returns ValidationFailure when an item is not a map',
      () async {
    final dataSource = SampleRemoteDataSource(
      _apiClientWithData([
        {'id': '1', 'title': 'Inventory'},
        'invalid',
      ]),
    );

    final result = await dataSource.getItems();

    expect(result, isA<FailureResult<List<SampleItemModel>>>());
    expect(
      result.when(
        success: (_) => null,
        failure: (failure) => failure,
      ),
      isA<ValidationFailure>(),
    );
  });

  test('getItems returns ValidationFailure when an item has invalid fields',
      () async {
    final dataSource = SampleRemoteDataSource(
      _apiClientWithData([
        {'id': '1', 'title': 42},
      ]),
    );

    final result = await dataSource.getItems();

    expect(result, isA<FailureResult<List<SampleItemModel>>>());
    expect(
      result.when(
        success: (_) => null,
        failure: (failure) => failure,
      ),
      isA<ValidationFailure>(),
    );
  });
}

ApiClient _apiClientWithData(Object? data) {
  final dio = Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: data,
            ),
          );
        },
      ),
    );

  return ApiClient(dio: dio);
}
