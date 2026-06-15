import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class AppSecureStorage {
  const AppSecureStorage({
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  static const String kAccessTokenKey = 'access_token';

  final FlutterSecureStorage _storage;

  Future<void> saveAccessToken(String token) {
    return _storage.write(key: kAccessTokenKey, value: token);
  }

  Future<String?> readAccessToken() {
    return _storage.read(key: kAccessTokenKey);
  }

  Future<void> clearAccessToken() {
    return _storage.delete(key: kAccessTokenKey);
  }
}
