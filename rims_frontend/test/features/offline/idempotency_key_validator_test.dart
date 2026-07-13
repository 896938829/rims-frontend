import 'package:flutter_test/flutter_test.dart';
import 'package:rims_frontend/features/offline/domain/services/idempotency_key_validator.dart';

void main() {
  test('accepts stable URL-safe operation keys up to 255 characters', () {
    expect(
      IdempotencyKeyValidator.isValid('request_1.document.complete'),
      isTrue,
    );
    expect(IdempotencyKeyValidator.isValid('a' * 255), isTrue);
  });

  test('rejects separators and lengths that cannot be sent in status URLs', () {
    expect(
      IdempotencyKeyValidator.isValid('request:documentComplete'),
      isFalse,
    );
    expect(IdempotencyKeyValidator.isValid('a' * 256), isFalse);
    expect(IdempotencyKeyValidator.isValid('.'), isFalse);
    expect(IdempotencyKeyValidator.isValid('..'), isFalse);
  });

  test('compose produces a validated stable lifecycle key', () {
    expect(
      IdempotencyKeyValidator.compose('request_1', 'documentComplete'),
      'request_1.documentComplete',
    );
    expect(
      () => IdempotencyKeyValidator.compose('a' * 250, 'documentComplete'),
      throwsArgumentError,
    );
  });
}
