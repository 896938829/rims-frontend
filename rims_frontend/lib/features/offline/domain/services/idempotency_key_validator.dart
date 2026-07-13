abstract final class IdempotencyKeyValidator {
  static final RegExp _urlSafePattern = RegExp(r'^[A-Za-z0-9._~-]+$');

  static bool isValid(String key) {
    if (key.isEmpty || key.length > 255 || key == '.' || key == '..') {
      return false;
    }
    return _urlSafePattern.hasMatch(key);
  }

  static String compose(String requestId, String kind) {
    final key = '$requestId.$kind';
    if (!isValid(key)) {
      throw ArgumentError.value(key, 'key', 'Invalid idempotency key');
    }
    return key;
  }
}
