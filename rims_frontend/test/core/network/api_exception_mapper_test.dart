import 'dart:io';

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

    test('maps connection timeout to NetworkFailure', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/test'),
          type: DioExceptionType.connectionTimeout,
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    for (final type in const [
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test('maps $type to TransportUnknownFailure', () {
        final failure = const ApiExceptionMapper().map(
          DioException(
            requestOptions: RequestOptions(path: '/documents'),
            type: type,
          ),
        );

        expect(failure, isA<TransportUnknownFailure>());
      });
    }

    test('maps connection error to NetworkFailure', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/documents'),
          type: DioExceptionType.connectionError,
          error: const SocketException('connection refused'),
        ),
      );

      expect(failure, isA<NetworkFailure>());
    });

    test('distinguishes an unknown transport result from protocol unknown', () {
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(path: '/documents'),
          type: DioExceptionType.unknown,
          error: const SocketException('connection closed without response'),
        ),
      );

      expect(failure, isA<TransportUnknownFailure>());
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

    test('transport cause excludes Dio credential graphs', () {
      const accessToken = 'mapper-access-secret';
      const refreshToken = 'mapper-refresh-secret';
      final failure = const ApiExceptionMapper().map(
        DioException(
          requestOptions: RequestOptions(
            path: '/auth/refresh',
            headers: {'Authorization': 'Bearer $accessToken'},
            data: {'refreshToken': refreshToken},
          ),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/auth/refresh'),
            statusCode: 500,
            data: {'echo': accessToken},
          ),
          error: StateError('nested $refreshToken'),
        ),
      );

      expect(failure.cause, isNot(isA<DioException>()));
      expect(failure.cause.toString(), isNot(contains(accessToken)));
      expect(failure.cause.toString(), isNot(contains(refreshToken)));
    });
  });
}
