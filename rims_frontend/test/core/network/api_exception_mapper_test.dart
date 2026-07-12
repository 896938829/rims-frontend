import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_exception_mapper.dart';
import 'package:rims_frontend/core/result/failure.dart';

void main() {
  group('ApiExceptionMapper', () {
    DioException exceptionForStatus(int statusCode, {Object? data}) {
      return DioException(
        requestOptions: RequestOptions(path: '/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: statusCode,
          data: data,
        ),
      );
    }

    test('maps RIMS auth code to AuthenticationFailure', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(
          401,
          data: {'code': 10001, 'message': '认证失败', 'traceId': 'trace-auth'},
        ),
      );

      expect(failure, isA<AuthenticationFailure>());
      expect(failure.message, '认证失败');
      expect(failure.businessCode, 10001);
      expect(failure.traceId, 'trace-auth');
    });

    test('maps RIMS inventory code to InventoryFailure', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(
          422,
          data: {
            'code': 20001,
            'message': '库存不足',
            'traceId': 'trace-inventory',
          },
        ),
      );

      expect(failure, isA<InventoryFailure>());
      expect(failure.message, '库存不足');
      expect(failure.businessCode, 20001);
      expect(failure.traceId, 'trace-inventory');
    });

    test('maps RIMS state code to StateFailure', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(
          422,
          data: {'code': 20002, 'message': '状态不允许', 'traceId': 'trace-state'},
        ),
      );

      expect(failure, isA<StateFailure>());
      expect(failure.message, '状态不允许');
      expect(failure.businessCode, 20002);
      expect(failure.traceId, 'trace-state');
    });

    test('keeps trace id when mapping HTTP authorization failures', () {
      final failure = const ApiExceptionMapper().map(
        exceptionForStatus(
          403,
          data: {'code': 0, 'message': '权限不足', 'traceId': 'trace-forbidden'},
        ),
      );

      expect(failure, isA<AuthorizationFailure>());
      expect(failure.message, '权限不足');
      expect(failure.statusCode, 403);
      expect(failure.businessCode, isNull);
      expect(failure.traceId, 'trace-forbidden');
    });

    test('maps timeout to NetworkFailure', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    test('maps request cancellation without treating it as authentication', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/upload'),
          type: DioExceptionType.cancel,
        ),
      );

      expect(failure, isA<CancellationFailure>());
    });
  });
}
