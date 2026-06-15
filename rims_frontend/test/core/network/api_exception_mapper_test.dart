import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/network/api_exception_mapper.dart';
import 'package:rims_frontend/core/result/failure.dart';

void main() {
  late ApiExceptionMapper mapper;

  setUp(() {
    mapper = const ApiExceptionMapper();
  });

  DioException exceptionForStatus(int statusCode) {
    return DioException(
      requestOptions: RequestOptions(path: '/test'),
      response: Response<dynamic>(
        requestOptions: RequestOptions(path: '/test'),
        statusCode: statusCode,
        data: {'message': 'Mapped message'},
      ),
    );
  }

  test('maps timeout to NetworkFailure', () {
    final failure = mapper.map(
      DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.connectionTimeout,
      ),
    );

    expect(failure, isA<NetworkFailure>());
  });

  test('maps 401 to AuthenticationFailure', () {
    final failure = mapper.map(exceptionForStatus(401));

    expect(failure, isA<AuthenticationFailure>());
    expect(failure.statusCode, 401);
    expect(failure.message, 'Mapped message');
  });

  test('maps 403 to AuthorizationFailure', () {
    final failure = mapper.map(exceptionForStatus(403));

    expect(failure, isA<AuthorizationFailure>());
  });

  test('maps 404 to NotFoundFailure', () {
    final failure = mapper.map(exceptionForStatus(404));

    expect(failure, isA<NotFoundFailure>());
  });

  test('maps 422 to ValidationFailure', () {
    final failure = mapper.map(exceptionForStatus(422));

    expect(failure, isA<ValidationFailure>());
  });

  test('maps 500 to ServerFailure', () {
    final failure = mapper.map(exceptionForStatus(500));

    expect(failure, isA<ServerFailure>());
  });
}
