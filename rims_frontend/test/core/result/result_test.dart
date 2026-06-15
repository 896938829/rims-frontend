import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/core/result/failure.dart';
import 'package:rims_frontend/core/result/result.dart';

void main() {
  group('Result', () {
    test('Success exposes data', () {
      const result = Success<int>(42);

      expect(result.data, 42);
    });

    test('FailureResult exposes failure', () {
      const failure = NetworkFailure(message: 'No connection');
      const result = FailureResult<int>(failure);

      expect(result.failure, failure);
      expect(result.failure.message, 'No connection');
    });
  });

  group('Failure', () {
    test('failures with same type and message are equal', () {
      const first = ServerFailure(message: 'Server error', statusCode: 500);
      const second = ServerFailure(message: 'Server error', statusCode: 500);

      expect(first, second);
    });

    test('unknown failure has default message', () {
      const failure = UnknownFailure();

      expect(failure.message, 'Unexpected error');
    });
  });
}
